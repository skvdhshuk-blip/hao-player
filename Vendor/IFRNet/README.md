# IFRNet-S（高质量流畅档）

上游：[ltkong218/IFRNet](https://github.com/ltkong218/IFRNet)，MIT。

本仓库只维护 **IFRNet-S**。完整 / L 变体不要加进来。

权重不进 `.app` 的 PyTorch 形态。开发机转换：

```bash
# 官方权重镜像之一
curl -L -o Vendor/IFRNet/IFRNet_S_Vimeo90K.pth \
  https://github.com/Fannovel16/ComfyUI-Frame-Interpolation/releases/download/models/IFRNet_S_Vimeo90K.pth

python3 scripts/export_ifrnet_coreml.py \
  --checkpoint Vendor/IFRNet/IFRNet_S_Vimeo90K.pth \
  --output Resources/IFRNet_S.mlpackage
```

`.pth` 不入库。随包的是 `Resources/IFRNet_S.mlpackage`。
