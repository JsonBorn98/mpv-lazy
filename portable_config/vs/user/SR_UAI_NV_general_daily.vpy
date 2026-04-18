### 通用超分：日常稳定档
### 基于官方 UAI_NV_TRT，使用通用型 HFA2kCompact 模型

import vapoursynth as vs
from vapoursynth import core
import k7sfunc as k7f

core.num_threads = k7f.vs_t_dft
clip = video_in

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

H_Pre = 1080
Model = "Sirosky_OpenProteus_Compact_x2_fp16_op17.onnx"
Fp16_Qnt = True
Gpu = 0
Gpu_T = 2
St_Eng = False
Res_Opt = [1920, 1080]
Res_Max = [3840, 2160]
Ws_Size = 0
H_Max = 2160
Lk_Fmt = False

clip = k7f.FMT_CTRL(clip, h_max=H_Pre, fmt_pix=1 if Lk_Fmt else 0)
Res_Opt, Res_Max = _resolve_trt_shapes(clip, Res_Max)
clip = k7f.UAI_NV_TRT(
    clip,
    crc=False,
    model_pth=Model,
    opt_lv=3,
    cuda_opt=[0, 0, 0],
    int8_qnt=False,
    fp16_qnt=Fp16_Qnt,
    gpu=Gpu,
    gpu_t=Gpu_T,
    st_eng=St_Eng,
    res_opt=Res_Opt,
    res_max=Res_Max,
    ws_size=Ws_Size,
)
clip = k7f.FMT_CTRL(clip, h_max=H_Max, fmt_pix=1 if Lk_Fmt else 0)

clip.set_output()
