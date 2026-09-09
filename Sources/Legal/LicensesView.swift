import SwiftUI

struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("许可证")
                    .font(.title2.weight(.semibold))
                Text(Self.bodyText)
                    .font(.system(.body, design: .default))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private static let bodyText = """
    Hao Player 源代码以 Apache License 2.0 发布。

    本应用只播放用户自己打开的本地文件，不采集、不跟踪。

    本应用动态链接 FFmpeg 7.1.1，FFmpeg 部分以 LGPL-2.1-or-later 授权（构建未启用 --enable-gpl / --enable-nonfree / --enable-version3）。上游：https://ffmpeg.org/

    书面提供（自本版本发布起三年）：可应要求提供该版本的目标文件和链接输入，以便用修改过的 LGPL 库重新链接。请联系应用开发者。构建脚本见仓库 scripts/build_ffmpeg_lgpl.sh。

    本应用嵌入 Anime4K（Fast Mode A）着色器，MIT License，Copyright (c) 2019-2021 bloc97。上游：https://github.com/bloc97/Anime4K

    本应用嵌入 IFRNet-S 插帧权重，MIT License，Copyright (c) 2022 Lingtong Kong。上游：https://github.com/ltkong218/IFRNet

    其他计划嵌入、且许可证允许上架的组件：
    - libass：ISC（尚未嵌入）

    禁止进入本仓库的组件：IINA、Glass Player、带 LuaJIT 的 libmpv、任何 GPL 源码。

    完整文本见应用包 Resources/LICENSES/。
    """
}
