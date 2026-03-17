/* CDC-ECM state struct offsets */

.equ ECM_IN_ADDR,      0       /* u8:  bulk IN endpoint address */
.equ ECM_OUT_ADDR,     1       /* u8:  bulk OUT endpoint address */
.equ ECM_IN_MPS,       2       /* u16: bulk IN max packet size */
.equ ECM_OUT_MPS,      4       /* u16: bulk OUT max packet size */
                                /* 6-7: padding */
.equ ECM_IN_PID,       8       /* u32: bulk IN DATA toggle (HCTSIZ_PID_DATAx) */
.equ ECM_OUT_PID,      12      /* u32: bulk OUT DATA toggle (HCTSIZ_PID_DATAx) */
.equ ECM_SIZE,         16
