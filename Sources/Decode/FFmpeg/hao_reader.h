#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HaoReader HaoReader;

typedef struct {
    void *pixelBuffer;
    double pts;
    double duration;
} HaoVideoFrame;

typedef struct {
    float *pcm;
    int frameCount;
    int sampleRate;
    double pts;
} HaoAudioFrame;

enum {
    HAO_EOF = 0,
    HAO_VIDEO = 1,
    HAO_AUDIO = 2,
};

int HaoReaderOpen(void **out, const char *path);
void HaoReaderClose(void *reader);
double HaoReaderDuration(const void *reader);
int HaoReaderHasVideo(const void *reader);
int HaoReaderHasAudio(const void *reader);
int HaoReaderAudioRate(const void *reader);
int HaoReaderSeek(void *reader, double seconds);
int HaoReaderRead(void *reader, int *kind, HaoVideoFrame *video, HaoAudioFrame *audio);
const char *HaoReaderLastError(const void *reader);

#ifdef __cplusplus
}
#endif
