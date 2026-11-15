# 调查记录

## 现象与实测

GU603VV / BIOS 315，使用约 100 W USB-C PD。设置 80% 电池保护上限后，达到上限时 PD 输入降为 0 W；电量下降至约 78% 后恢复充电。两个 USB-C 口均观察到类似现象，圆口供电达到上限后则能继续供电。

原项目记录的修复效果：

| 停充状态 | 外部 PD 输入 | 电池电流 |
| --- | --- | --- |
| 修复前 | 0 W | 约 2820–3007 mA 放电 |
| 修复后 | 约 40 W 以上 | 约 15–27 mA |

## 控制链

前期 ACPI/EC 离线分析找到限充命令、停充时电流目标清零及电压目标跟随电池电压的路径。后续运行时试验得到有效参数组合：纯 PD 且 `State=6` 时，将零电流目标 `0x14` 改为 `0x0040`，并把过低的 `0x15` 目标提高至 17000。

脚本通过 ASUS WMI 与共享 EC SMBus 邮筒访问，检查目标芯片 ID `0x0049:0x000C`，使用原脚本的地址白名单、参数范围和进程间互斥。该 ID 尚不足以唯一确定具体芯片型号。现有结果确认本机的软件运行时修复有效，完整板级电路和长期电池影响仍需更多实测。

当前脚本保留原始修复方案，补充两类通信异常处理：WMI 返回空数据时报错，SMBus 等待超时后中止本轮。这些补丁通过离线模拟检查，真机效果由维护者验证。

## 参考资料

- [G-Helper #1030：USB-C charging hammering battery](https://github.com/seerge/g-helper/discussions/1030)
- [ASUS GU603VV 官方资料](https://www.asus.com/supportonly/gu603vv/helpdesk_service_guide/)
- [Renesas ISL9238A 数据手册](https://www.renesas.com/en/document/dst/isl9238a-datasheet)
- [ACPI EC-SMBus 接口](https://uefi.org/specs/ACPI/6.5/12_Embedded_Controller_Interface_Specification.html)
