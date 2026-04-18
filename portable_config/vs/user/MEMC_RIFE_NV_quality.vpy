### 通用补帧：高分辨率源适配档
### 基于官方 RIFE_NV，面向 1440p/2160p 源在 RTX 5070 Ti 上逼近性能上限

import vapoursynth as vs
from vapoursynth import core
import k7sfunc as k7f

core.num_threads = k7f.vs_t_dft
clip = video_in

def _resolve_src_fps(src_clip: vs.VideoNode, fallback: float = 23.976) -> float:
    fps = globals().get("container_fps", 0.0)
    try:
        fps = float(fps)
    except (TypeError, ValueError):
        fps = 0.0
    if fps <= 0.0 and src_clip.fps_num > 0 and src_clip.fps_den > 0:
        fps = src_clip.fps_num / src_clip.fps_den
    return fps if fps > 0.0 else fallback

############
# 用户选项 #
############

H_Pre = 2160
Model = 46
Fps_Num = 2
Fps_Den = 1
Sc_Mode = 2
Gpu = 0
Gpu_T = 3
Ws_Size = 0
Lk_Fmt = False
## 高分辨率档改用更轻模型，腾出预算给更高的输入上限与更强场切检测

Src_Fps = _resolve_src_fps(clip)
clip = k7f.FMT_CTRL(clip, h_max=H_Pre, fmt_pix=1 if Lk_Fmt else 0)
clip = k7f.RIFE_NV(
    clip,
    model=Model,
    int8_qnt=False,
    turbo=2,
    fps_in=Src_Fps,
    fps_num=Fps_Num,
    fps_den=Fps_Den,
    sc_mode=Sc_Mode,
    gpu=Gpu,
    gpu_t=Gpu_T,
    ws_size=Ws_Size,
)

clip.set_output()
