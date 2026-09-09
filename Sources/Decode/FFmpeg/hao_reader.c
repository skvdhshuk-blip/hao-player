#include "hao_reader.h"

#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct HaoReader {
    AVFormatContext *fmt;
    AVCodecContext *video;
    AVCodecContext *audio;
    struct SwsContext *sws;
    struct SwrContext *swr;
    AVPacket *packet;
    AVFrame *frame;
    int video_stream;
    int audio_stream;
    int audio_rate;
    int flushing;
    char error[256];
};

static char g_last_error[256];

static enum AVPixelFormat hao_pick_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    (void)ctx;
    const enum AVPixelFormat *p;
    for (p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *p;
        }
    }
    return pix_fmts[0];
}

static void hao_set_error(HaoReader *reader, int code, const char *fallback) {
    if (code < 0) {
        av_strerror(code, reader->error, sizeof(reader->error));
    } else if (fallback) {
        snprintf(reader->error, sizeof(reader->error), "%s", fallback);
    }
    snprintf(g_last_error, sizeof(g_last_error), "%s", reader->error);
}

static int hao_open_codec(AVFormatContext *fmt, int index, int want_vt, AVCodecContext **out) {
    AVStream *stream = fmt->streams[index];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        return AVERROR_DECODER_NOT_FOUND;
    }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        return AVERROR(ENOMEM);
    }
    int err = avcodec_parameters_to_context(ctx, stream->codecpar);
    if (err < 0) {
        avcodec_free_context(&ctx);
        return err;
    }
    ctx->pkt_timebase = stream->time_base;
    if (want_vt) {
        AVBufferRef *hw = NULL;
        if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
            ctx->hw_device_ctx = hw;
            ctx->get_format = hao_pick_format;
            ctx->thread_count = 1;
        }
    }
    err = avcodec_open2(ctx, codec, NULL);
    if (err < 0) {
        avcodec_free_context(&ctx);
        return err;
    }
    *out = ctx;
    return 0;
}

static int hao_make_bgra(HaoReader *reader, AVFrame *src, CVPixelBufferRef *out) {
    AVFrame *sw = src;
    AVFrame *transferred = NULL;
    if (src->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        transferred = av_frame_alloc();
        if (!transferred) {
            return AVERROR(ENOMEM);
        }
        int err = av_hwframe_transfer_data(transferred, src, 0);
        if (err < 0) {
            av_frame_free(&transferred);
            return err;
        }
        sw = transferred;
    }

    reader->sws = sws_getCachedContext(
        reader->sws,
        sw->width,
        sw->height,
        (enum AVPixelFormat)sw->format,
        sw->width,
        sw->height,
        AV_PIX_FMT_BGRA,
        SWS_BILINEAR,
        NULL,
        NULL,
        NULL
    );
    if (!reader->sws) {
        av_frame_free(&transferred);
        return AVERROR(EINVAL);
    }

    CVPixelBufferRef buffer = NULL;
    CFDictionaryRef attrs = NULL;
    int err = CVPixelBufferCreate(
        kCFAllocatorDefault,
        sw->width,
        sw->height,
        kCVPixelFormatType_32BGRA,
        attrs,
        &buffer
    );
    if (err != kCVReturnSuccess || !buffer) {
        av_frame_free(&transferred);
        return AVERROR(ENOMEM);
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *dest = CVPixelBufferGetBaseAddress(buffer);
    int dest_stride = (int)CVPixelBufferGetBytesPerRow(buffer);
    uint8_t *dest_planes[4] = { dest, NULL, NULL, NULL };
    int dest_strides[4] = { dest_stride, 0, 0, 0 };
    sws_scale(reader->sws, (const uint8_t *const *)sw->data, sw->linesize, 0, sw->height, dest_planes, dest_strides);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    av_frame_free(&transferred);
    *out = buffer;
    return 0;
}

static double hao_pts_seconds(const HaoReader *reader, const AVStream *stream, int64_t pts) {
    if (pts == AV_NOPTS_VALUE) {
        return 0;
    }
    double t = pts * av_q2d(stream->time_base);
    if (reader->fmt && reader->fmt->start_time != AV_NOPTS_VALUE) {
        t -= (double)reader->fmt->start_time / (double)AV_TIME_BASE;
    }
    return t < 0 ? 0 : t;
}

static int hao_fill_video(HaoReader *reader, HaoVideoFrame *video) {
    AVStream *stream = reader->fmt->streams[reader->video_stream];
    double tb = av_q2d(stream->time_base);
    int64_t pts = reader->frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) {
        pts = reader->frame->pts;
    }
    video->pts = hao_pts_seconds(reader, stream, pts);
    video->duration = reader->frame->duration > 0 ? reader->frame->duration * tb : av_q2d(stream->avg_frame_rate) > 0 ? 1.0 / av_q2d(stream->avg_frame_rate) : 0.04;

    if (reader->frame->format == AV_PIX_FMT_VIDEOTOOLBOX && reader->frame->data[3]) {
        CVPixelBufferRef pixel = (CVPixelBufferRef)reader->frame->data[3];
        CVPixelBufferRetain(pixel);
        video->pixelBuffer = pixel;
        return 0;
    }
    CVPixelBufferRef buffer = NULL;
    int err = hao_make_bgra(reader, reader->frame, &buffer);
    video->pixelBuffer = buffer;
    return err;
}

static int hao_fill_audio(HaoReader *reader, HaoAudioFrame *audio) {
    AVCodecContext *ctx = reader->audio;
    if (!reader->swr) {
        AVChannelLayout out_ch = AV_CHANNEL_LAYOUT_STEREO;
        int err = swr_alloc_set_opts2(
            &reader->swr,
            &out_ch,
            AV_SAMPLE_FMT_FLT,
            ctx->sample_rate,
            &ctx->ch_layout,
            ctx->sample_fmt,
            ctx->sample_rate,
            0,
            NULL
        );
        if (err < 0 || swr_init(reader->swr) < 0) {
            return AVERROR(EINVAL);
        }
        reader->audio_rate = ctx->sample_rate;
    }

    int out_count = swr_get_out_samples(reader->swr, reader->frame->nb_samples);
    if (out_count <= 0) {
        out_count = reader->frame->nb_samples;
    }
    float *pcm = malloc((size_t)out_count * 2 * sizeof(float));
    if (!pcm) {
        return AVERROR(ENOMEM);
    }
    uint8_t *dest[1] = { (uint8_t *)pcm };
    int converted = swr_convert(
        reader->swr,
        dest,
        out_count,
        (const uint8_t **)reader->frame->extended_data,
        reader->frame->nb_samples
    );
    if (converted < 0) {
        free(pcm);
        return converted;
    }
    AVStream *stream = reader->fmt->streams[reader->audio_stream];
    int64_t pts = reader->frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) {
        pts = reader->frame->pts;
    }
    audio->pcm = pcm;
    audio->frameCount = converted;
    audio->sampleRate = reader->audio_rate;
    audio->pts = hao_pts_seconds(reader, stream, pts);
    return 0;
}

int HaoReaderOpen(void **out, const char *path) {
    if (out) {
        *out = NULL;
    }
    g_last_error[0] = 0;
    HaoReader *reader = calloc(1, sizeof(*reader));
    if (!reader) {
        snprintf(g_last_error, sizeof(g_last_error), "out of memory");
        return AVERROR(ENOMEM);
    }
    reader->video_stream = -1;
    reader->audio_stream = -1;
    int err = avformat_open_input(&reader->fmt, path, NULL, NULL);
    if (err < 0) {
        hao_set_error(reader, err, NULL);
        HaoReaderClose(reader);
        return err;
    }
    err = avformat_find_stream_info(reader->fmt, NULL);
    if (err < 0) {
        hao_set_error(reader, err, NULL);
        HaoReaderClose(reader);
        return err;
    }
    reader->video_stream = av_find_best_stream(reader->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    reader->audio_stream = av_find_best_stream(reader->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (reader->video_stream < 0) {
        hao_set_error(reader, 0, "no video stream");
        HaoReaderClose(reader);
        return AVERROR_STREAM_NOT_FOUND;
    }
    err = hao_open_codec(reader->fmt, reader->video_stream, 1, &reader->video);
    if (err < 0) {
        hao_set_error(reader, err, NULL);
        HaoReaderClose(reader);
        return err;
    }
    if (reader->audio_stream >= 0) {
        err = hao_open_codec(reader->fmt, reader->audio_stream, 0, &reader->audio);
        if (err < 0) {
            reader->audio_stream = -1;
            reader->audio = NULL;
        } else {
            reader->audio_rate = reader->audio->sample_rate;
        }
    }
    reader->packet = av_packet_alloc();
    reader->frame = av_frame_alloc();
    if (!reader->packet || !reader->frame) {
        HaoReaderClose(reader);
        return AVERROR(ENOMEM);
    }
    *out = reader;
    return 0;
}

void HaoReaderClose(void *raw) {
    HaoReader *reader = raw;
    if (!reader) {
        return;
    }
    sws_freeContext(reader->sws);
    swr_free(&reader->swr);
    av_packet_free(&reader->packet);
    av_frame_free(&reader->frame);
    avcodec_free_context(&reader->video);
    avcodec_free_context(&reader->audio);
    avformat_close_input(&reader->fmt);
    free(reader);
}

double HaoReaderDuration(const void *raw) {
    const HaoReader *reader = raw;
    if (!reader || !reader->fmt || reader->fmt->duration <= 0) {
        return 0;
    }
    return (double)reader->fmt->duration / (double)AV_TIME_BASE;
}

int HaoReaderHasVideo(const void *raw) {
    const HaoReader *reader = raw;
    return reader && reader->video_stream >= 0;
}

int HaoReaderHasAudio(const void *raw) {
    const HaoReader *reader = raw;
    return reader && reader->audio_stream >= 0;
}

int HaoReaderAudioRate(const void *raw) {
    const HaoReader *reader = raw;
    return reader ? reader->audio_rate : 0;
}

int HaoReaderSeek(void *raw, double seconds) {
    HaoReader *reader = raw;
    if (!reader || !reader->fmt) {
        return AVERROR(EINVAL);
    }
    int64_t ts = (int64_t)(seconds * AV_TIME_BASE);
    if (reader->fmt->start_time != AV_NOPTS_VALUE) {
        ts += reader->fmt->start_time;
    }
    int err = avformat_seek_file(reader->fmt, -1, INT64_MIN, ts, INT64_MAX, 0);
    if (err < 0) {
        hao_set_error(reader, err, NULL);
        return err;
    }
    if (reader->video) {
        avcodec_flush_buffers(reader->video);
    }
    if (reader->audio) {
        avcodec_flush_buffers(reader->audio);
    }
    reader->flushing = 0;
    return 0;
}

static int hao_receive(HaoReader *reader, AVCodecContext *ctx, int kind, HaoVideoFrame *video, HaoAudioFrame *audio) {
    av_frame_unref(reader->frame);
    int err = avcodec_receive_frame(ctx, reader->frame);
    if (err == AVERROR(EAGAIN) || err == AVERROR_EOF) {
        return err;
    }
    if (err < 0) {
        hao_set_error(reader, err, NULL);
        return err;
    }
    if (kind == HAO_VIDEO) {
        err = hao_fill_video(reader, video);
    } else {
        err = hao_fill_audio(reader, audio);
    }
    av_frame_unref(reader->frame);
    return err;
}

int HaoReaderRead(void *raw, int *kind, HaoVideoFrame *video, HaoAudioFrame *audio) {
    HaoReader *reader = raw;
    if (!reader || !kind) {
        return AVERROR(EINVAL);
    }
    *kind = HAO_EOF;
    memset(video, 0, sizeof(*video));
    memset(audio, 0, sizeof(*audio));

    while (1) {
        if (!reader->flushing) {
            int err = av_read_frame(reader->fmt, reader->packet);
            if (err == AVERROR_EOF) {
                reader->flushing = 1;
                if (reader->video) {
                    avcodec_send_packet(reader->video, NULL);
                }
                if (reader->audio) {
                    avcodec_send_packet(reader->audio, NULL);
                }
            } else if (err < 0) {
                hao_set_error(reader, err, NULL);
                return err;
            } else {
                AVCodecContext *ctx = NULL;
                int next_kind = 0;
                if (reader->packet->stream_index == reader->video_stream) {
                    ctx = reader->video;
                    next_kind = HAO_VIDEO;
                } else if (reader->packet->stream_index == reader->audio_stream) {
                    ctx = reader->audio;
                    next_kind = HAO_AUDIO;
                }
                if (ctx) {
                    err = avcodec_send_packet(ctx, reader->packet);
                    av_packet_unref(reader->packet);
                    if (err < 0 && err != AVERROR(EAGAIN)) {
                        hao_set_error(reader, err, NULL);
                        return err;
                    }
                    err = hao_receive(reader, ctx, next_kind, video, audio);
                    if (err == 0) {
                        *kind = next_kind;
                        return 0;
                    }
                    if (err != AVERROR(EAGAIN) && err != AVERROR_EOF) {
                        return err;
                    }
                    continue;
                }
                av_packet_unref(reader->packet);
                continue;
            }
        }

        if (reader->video) {
            int err = hao_receive(reader, reader->video, HAO_VIDEO, video, audio);
            if (err == 0) {
                *kind = HAO_VIDEO;
                return 0;
            }
            if (err != AVERROR(EAGAIN) && err != AVERROR_EOF) {
                return err;
            }
        }
        if (reader->audio) {
            int err = hao_receive(reader, reader->audio, HAO_AUDIO, video, audio);
            if (err == 0) {
                *kind = HAO_AUDIO;
                return 0;
            }
            if (err != AVERROR(EAGAIN) && err != AVERROR_EOF) {
                return err;
            }
        }
        *kind = HAO_EOF;
        return 0;
    }
}

const char *HaoReaderLastError(const void *raw) {
    const HaoReader *reader = raw;
    if (reader && reader->error[0]) {
        return reader->error;
    }
    return g_last_error;
}
