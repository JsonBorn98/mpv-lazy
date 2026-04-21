### 高负载实验项：补帧 + 动漫超分组合
### 组合 RIFE_NV 与 UAI_NV_TRT；RIFE 段刻意保留较轻模型给 UAI 留余量

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

def _align_trt_shape(size: int, minimum: int = 384) -> int:
    aligned = int(size) // 2 * 2
    return max(minimum, aligned)

def _resolve_trt_shapes(src_clip: vs.VideoNode, max_limit: list[int]) -> tuple[list[int], list[int]]:
    src_w = _align_trt_shape(src_clip.width)
    src_h = _align_trt_shape(src_clip.height)
    max_w = _align_trt_shape(min(max_limit[0], max(src_w, 384)))
    max_h = _align_trt_shape(min(max_limit[1], max(src_h, 384)))
    opt_w = min(src_w, max_w)
    opt_h = min(src_h, max_h)
    return [opt_w, opt_h], [max_w, max_h]

############
# 用户选项 #
############

RIFE_H_Pre = 1080
RIFE_Model = 426
Turbo = 2
Fps_Num = 2
Fps_Den = 1
Sc_Mode = 1
Gpu = 0
Gpu_T = 2
RIFE_Ws_Size = 0

UAI_H_Pre = 1080
UAI_Model = "2x_AnimeJaNai_HD_V3_SuperUltraCompact.onnx"
Fp16_Qnt = True
St_Eng = False
Res_Opt = [1920, 1080]
Res_Max = [3840, 2160]
UAI_Ws_Size = 0
H_Max = 2160
Lk_Fmt = False

Src_Fps = _resolve_src_fps(clip)
clip = k7f.FMT_CTRL(clip, h_max=RIFE_H_Pre, fmt_pix=1 if Lk_Fmt else 0)
clip = k7f.RIFE_NV(
    clip,
    model=RIFE_Model,
    int8_qnt=False,
    turbo=Turbo,
    fps_in=Src_Fps,
    fps_num=Fps_Num,
    fps_den=Fps_Den,
    sc_mode=Sc_Mode,
    gpu=Gpu,
    gpu_t=Gpu_T,
    ws_size=RIFE_Ws_Size,
)

clip = k7f.FMT_CTRL(clip, h_max=UAI_H_Pre, fmt_pix=1 if Lk_Fmt else 0)
Res_Opt, Res_Max = _resolve_trt_shapes(clip, Res_Max)
clip = k7f.UAI_NV_TRT(
    clip,
    crc=False,
    model_pth=UAI_Model,
    opt_lv=3,
    cuda_opt=[0, 0, 0],
    int8_qnt=False,
    fp16_qnt=Fp16_Qnt,
    gpu=Gpu,
    gpu_t=Gpu_T,
    st_eng=St_Eng,
    res_opt=Res_Opt,
    res_max=Res_Max,
    ws_size=UAI_Ws_Size,
)
clip = k7f.FMT_CTRL(clip, h_max=H_Max, fmt_pix=1 if Lk_Fmt else 0)

clip.set_output()
