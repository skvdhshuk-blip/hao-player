bloc97/Anime4K（MIT）Fast Mode A 的上游 GLSL。

重新生成 Metal：

```
python3 scripts/glsl_hooks_to_metal.py \
  Vendor/Anime4K/glsl/Anime4K_Clamp_Highlights.glsl \
  Vendor/Anime4K/glsl/Anime4K_Restore_CNN_M.glsl \
  Vendor/Anime4K/glsl/Anime4K_Upscale_CNN_x2_M.glsl \
  Sources/Enhance/Anime4K/Anime4KFastA.metal
```
