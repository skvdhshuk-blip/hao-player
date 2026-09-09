"""IFRNet-S for CoreML export. Architecture from ltkong218/IFRNet (MIT)."""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


def warp(img: torch.Tensor, flow: torch.Tensor) -> torch.Tensor:
    batch, _, height, width = flow.shape
    xs = torch.arange(width, device=img.device, dtype=img.dtype) * (2.0 / (width - 1.0)) - 1.0
    ys = torch.arange(height, device=img.device, dtype=img.dtype) * (2.0 / (height - 1.0)) - 1.0
    grid_y, grid_x = torch.meshgrid(ys, xs, indexing="ij")
    grid = torch.stack([grid_x, grid_y], 0).unsqueeze(0).expand(batch, -1, -1, -1)
    flow_n = torch.cat(
        [
            flow[:, 0:1] / ((width - 1.0) / 2.0),
            flow[:, 1:2] / ((height - 1.0) / 2.0),
        ],
        1,
    )
    return F.grid_sample(
        img,
        (grid + flow_n).permute(0, 2, 3, 1),
        mode="bilinear",
        padding_mode="border",
        align_corners=True,
    )


def resize(x: torch.Tensor, scale_factor: float) -> torch.Tensor:
    return F.interpolate(x, scale_factor=scale_factor, mode="bilinear", align_corners=False)


def convrelu(in_channels: int, out_channels: int, kernel_size: int = 3, stride: int = 1, padding: int = 1):
    return nn.Sequential(
        nn.Conv2d(in_channels, out_channels, kernel_size, stride, padding, bias=True),
        nn.PReLU(out_channels),
    )


class ResBlock(nn.Module):
    def __init__(self, in_channels: int, side_channels: int):
        super().__init__()
        self.side_channels = side_channels
        self.conv1 = nn.Sequential(nn.Conv2d(in_channels, in_channels, 3, 1, 1, bias=True), nn.PReLU(in_channels))
        self.conv2 = nn.Sequential(nn.Conv2d(side_channels, side_channels, 3, 1, 1, bias=True), nn.PReLU(side_channels))
        self.conv3 = nn.Sequential(nn.Conv2d(in_channels, in_channels, 3, 1, 1, bias=True), nn.PReLU(in_channels))
        self.conv4 = nn.Sequential(nn.Conv2d(side_channels, side_channels, 3, 1, 1, bias=True), nn.PReLU(side_channels))
        self.conv5 = nn.Conv2d(in_channels, in_channels, 3, 1, 1, bias=True)
        self.prelu = nn.PReLU(in_channels)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self.conv1(x)
        side = self.conv2(out[:, -self.side_channels :])
        out = torch.cat([out[:, : -self.side_channels], side], 1)
        out = self.conv3(out)
        side = self.conv4(out[:, -self.side_channels :])
        out = torch.cat([out[:, : -self.side_channels], side], 1)
        return self.prelu(x + self.conv5(out))


class Encoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.pyramid1 = nn.Sequential(convrelu(3, 24, 3, 2, 1), convrelu(24, 24, 3, 1, 1))
        self.pyramid2 = nn.Sequential(convrelu(24, 36, 3, 2, 1), convrelu(36, 36, 3, 1, 1))
        self.pyramid3 = nn.Sequential(convrelu(36, 54, 3, 2, 1), convrelu(54, 54, 3, 1, 1))
        self.pyramid4 = nn.Sequential(convrelu(54, 72, 3, 2, 1), convrelu(72, 72, 3, 1, 1))

    def forward(self, img: torch.Tensor):
        f1 = self.pyramid1(img)
        f2 = self.pyramid2(f1)
        f3 = self.pyramid3(f2)
        f4 = self.pyramid4(f3)
        return f1, f2, f3, f4


class Decoder4(nn.Module):
    def __init__(self):
        super().__init__()
        self.convblock = nn.Sequential(convrelu(144 + 1, 144), ResBlock(144, 24), nn.ConvTranspose2d(144, 58, 4, 2, 1, bias=True))

    def forward(self, f0: torch.Tensor, f1: torch.Tensor, embt: torch.Tensor) -> torch.Tensor:
        _, _, height, width = f0.shape
        return self.convblock(torch.cat([f0, f1, embt.expand(-1, -1, height, width)], 1))


class Decoder3(nn.Module):
    def __init__(self):
        super().__init__()
        self.convblock = nn.Sequential(convrelu(166, 162), ResBlock(162, 24), nn.ConvTranspose2d(162, 40, 4, 2, 1, bias=True))

    def forward(self, ft: torch.Tensor, f0: torch.Tensor, f1: torch.Tensor, up_flow0: torch.Tensor, up_flow1: torch.Tensor) -> torch.Tensor:
        return self.convblock(torch.cat([ft, warp(f0, up_flow0), warp(f1, up_flow1), up_flow0, up_flow1], 1))


class Decoder2(nn.Module):
    def __init__(self):
        super().__init__()
        self.convblock = nn.Sequential(convrelu(112, 108), ResBlock(108, 24), nn.ConvTranspose2d(108, 28, 4, 2, 1, bias=True))

    def forward(self, ft: torch.Tensor, f0: torch.Tensor, f1: torch.Tensor, up_flow0: torch.Tensor, up_flow1: torch.Tensor) -> torch.Tensor:
        return self.convblock(torch.cat([ft, warp(f0, up_flow0), warp(f1, up_flow1), up_flow0, up_flow1], 1))


class Decoder1(nn.Module):
    def __init__(self):
        super().__init__()
        self.convblock = nn.Sequential(convrelu(76, 72), ResBlock(72, 24), nn.ConvTranspose2d(72, 8, 4, 2, 1, bias=True))

    def forward(self, ft: torch.Tensor, f0: torch.Tensor, f1: torch.Tensor, up_flow0: torch.Tensor, up_flow1: torch.Tensor) -> torch.Tensor:
        return self.convblock(torch.cat([ft, warp(f0, up_flow0), warp(f1, up_flow1), up_flow0, up_flow1], 1))


class IFRNetS(nn.Module):
    def __init__(self):
        super().__init__()
        self.encoder = Encoder()
        self.decoder4 = Decoder4()
        self.decoder3 = Decoder3()
        self.decoder2 = Decoder2()
        self.decoder1 = Decoder1()

    def forward(self, img0: torch.Tensor, img1: torch.Tensor, timestep: torch.Tensor) -> torch.Tensor:
        mean = torch.cat([img0, img1], 2).mean(dim=(1, 2, 3), keepdim=True)
        img0 = img0 - mean
        img1 = img1 - mean
        f0_1, f0_2, f0_3, f0_4 = self.encoder(img0)
        f1_1, f1_2, f1_3, f1_4 = self.encoder(img1)

        out4 = self.decoder4(f0_4, f1_4, timestep)
        up_flow0_4 = out4[:, 0:2]
        up_flow1_4 = out4[:, 2:4]
        ft_3 = out4[:, 4:]

        out3 = self.decoder3(ft_3, f0_3, f1_3, up_flow0_4, up_flow1_4)
        up_flow0_3 = out3[:, 0:2] + 2.0 * resize(up_flow0_4, 2.0)
        up_flow1_3 = out3[:, 2:4] + 2.0 * resize(up_flow1_4, 2.0)
        ft_2 = out3[:, 4:]

        out2 = self.decoder2(ft_2, f0_2, f1_2, up_flow0_3, up_flow1_3)
        up_flow0_2 = out2[:, 0:2] + 2.0 * resize(up_flow0_3, 2.0)
        up_flow1_2 = out2[:, 2:4] + 2.0 * resize(up_flow1_3, 2.0)
        ft_1 = out2[:, 4:]

        out1 = self.decoder1(ft_1, f0_1, f1_1, up_flow0_2, up_flow1_2)
        up_flow0_1 = out1[:, 0:2] + 2.0 * resize(up_flow0_2, 2.0)
        up_flow1_1 = out1[:, 2:4] + 2.0 * resize(up_flow1_2, 2.0)
        up_mask = torch.sigmoid(out1[:, 4:5])
        up_res = out1[:, 5:]

        merged = up_mask * warp(img0, up_flow0_1) + (1 - up_mask) * warp(img1, up_flow1_1) + mean
        return torch.clamp(merged + up_res, 0, 1)
