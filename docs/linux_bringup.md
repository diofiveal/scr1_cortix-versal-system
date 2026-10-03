# Cortix-SCR1 + Linux на ALINX VD100

## Статус и границы проверки

Исходная аппаратная сборка пользователя рабочая: timing закрыт, Device Image
успешно получен. Новая Linux-конфигурация меняет CIPS/NoC/clock tree, поэтому
успех исходной сборки **не является** результатом проверки этого изменения.

Здесь проверены выполнение Tcl-процедур на mock API, синтаксис и подготовка
конфигурации. Vivado 2023.2 / PetaLinux 2023.2, экспорт реального XSA, запись SD
и запуск платы в среде автора изменения недоступны. Эти пункты остаются
обязательными проверками на машине пользователя. Ни XSA, ни Linux boot не
объявляются успешно выполненными до реального запуска.

## Что объединено

Из ALINX `VD100_2023.2`, commit `902446432c7d60a2968d96f8b02a7c57e00cc7e6`,
`Demo/course_s2` перенесена конфигурация PS/PMC для этой платы: SD1, eMMC/SD0,
UART0 (115200), GEM0 на MIO, USB, QSPI и PMC I2C. Включены native DDR-пути PMC
и LPD. Камеры, LCD, VDMA и GEM1 через EMIO в минимальный проект не включены;
их device-tree phandles и демонстрационные драйверы не копируются.

Debug-конфигурация сохраняет A72/SCR1 MMIO-адреса, исправляет их RTL-трансляцию,
ограничивает external DDR для SCR1 и добавляет независимый LPD-вход в SmartConnect.
Новые PDI/XSA/LTX требуют новой synthesis/implementation; старый PDI этих изменений
не содержит. Адреса:

| Область | A72/Linux | SCR1 |
|---|---|---|
| Control | `0xA4000000`, 4 КиБ | `0xFF000000` (alias) |
| Boot BRAM | `0xA4010000`, 64 КиБ | `0xFFFF0000` (alias/reset vector) |
| Readiness GPIO | `0xA4020000`, 4 КиБ | host-only |
| Shared DDR | `0x7F000000`, 16 МиБ | `0x7F000000` |

`reserved-memory/no-map` исключает shared DDR из обычного Linux allocation.
Это не реализует coherency: драйвер/host-loader и cache maintenance потребуются
на следующем этапе. SCR1 не запускается автоматически при загрузке Linux;
readiness GPIO после reset остаётся нулевым. Сейчас цель — Linux shell с
аппаратной подсистемой SCR1, а не выполнение его firmware.

## PLL и тактовые домены

`CIPS/pl0_ref_clk` (nominal 100 МГц) → `pll_pl_scr1/clk_in1`.
`pll_pl_scr1/clk_out1` (requested 90 МГц) → SCR1, FPD AXI clock,
LPD AXI clock, SmartConnect, readiness GPIO, AXIS ILA, NoC `aclk4`,
`slowest_sync_clk`, `pl_clk_o`.
`pll_pl_scr1/locked` → `proc_sys_reset_0/dcm_locked`.

90 МГц выбраны по контексту ранее закрытого timing, не по старой цели 100 МГц.
Из-за фактического CIPS clock возможны нецелые Hz (ранее около `90000038`).
Tcl читает **текущие** `CONFIG.FREQ_HZ` на выходе PLL и передаёт их внешним
AXI-портам; значения `99999001`/`90000038` не зашиты как реальные результаты.
Native CCI/PMC/LPD NoC clocks остаются собственными clocks CIPS. Board reference 200 МГц
через IBUFDS питает DDR. Искусственных timing exceptions не добавлено.

## Ограничение адресов и software contract

| Мастер | DDR через NoC | Control | Boot BRAM | GPIO |
|---|---|---|---|---|
| Native CCI / PMC / LPD NoC | `0x00000000–0x7FFFFFFF`, 2 ГиБ | — | — | — |
| A72 FPD / SmartConnect S00 | исключён | `0xA4000000`, 4 КиБ | `0xA4010000`, 64 КиБ | `0xA4020000`, 4 КиБ |
| SCR1 IMEM / S01 | `0x7F000000–0x7FFFFFFF`, 16 МиБ | исключён | alias `0xFFFF0000` | исключён |
| SCR1 DMEM / S02 | `0x7F000000–0x7FFFFFFF`, 16 МиБ | alias `0xFF000000`, 4 КиБ | alias `0xFFFF0000` | исключён |
| DPC → CIPS LPD / S03 | исключён | `0x80000000`, 4 КиБ | `0x80010000`, 64 КиБ | `0x80020000`, 4 КиБ |

`address_map.tcl` задаёт окна отдельно для каждого SI. Linux allocator может
использовать DDR ниже `0x7F000000`; верхние 16 МиБ исключены `reserved-memory`
с `no-map`. Native PS DDR остаётся полной: reservation выполняет Linux,
аппаратный фильтр ограничивает SCR1. Отсутствующая адресная цель должна дать
AXI DECERR; это требуется проверить на реальном SmartConnect. Фильтр не даёт
таймаут зависшей корректно адресованной цели и не обеспечивает coherency.

`vd100_scr1_top.sv` переводит **только** 4-КиБ control alias `0xFF000000–0xFF000FFF`
в `0xA4000000–0xA4000FFF` и 64-КиБ Boot alias `0xFFFF0000–0xFFFFFFFF` в
`0xA4010000–0xA401FFFF`, сохраняя offset. Другие адреса не переписываются.
TCM `0xF0000000` / 64 КиБ и timer `0xF0040000` / 32 байта обслуживаются внутри
SCR1 и не требуют внешнего окна SmartConnect.

Общий software contract: `include/scr1_platform.h`, включаемый из
`linux/include/scr1_platform.h` и `firmware/include/scr1_platform.h`. Это заголовки
для будущих компонентов, готовый Linux-драйвер/firmware этим изменением не добавлен.
Драйвер должен брать ресурсы из DT, проверять `IP_ID=0x5343544C` и `HW_CONFIG[7:0]=90`.
GPIO в `system-user.dtsi` закреплён за A72-адресом, чтобы debug alias LPD не стал
Linux MMIO resource. Не запускай одновременно Linux-драйвер и XSDB запись одних
регистров: debug-вход обходит software locking.

Таймауты измеряются в control-clock cycles: reset defaults START=9 000 000
(100 мс), QUIESCE=90 000 (1 мс), WATCHDOG=90 000 000 (1 с, enable=0).
`SCR1_PTFM_CORE_CLK_FREQ` и header используют nominal 90 000 000 Гц; небольшая
погрешность PLL metadata не меняет единиц ABI. Эти lifecycle таймауты не спасают
A72/DPC от неотвечающего AXI slave; `AXI_TIMEOUT_CYCLES=0` оставлен без изменений.

Linker templates `firmware/linker/scr1_boot_bram.ld`, `scr1_tcm.ld`,
`scr1_shared_ddr.ld` размещают firmware только в соответствующих окнах и
резервируют 4 КиБ stack. Boot firmware должна предоставить `_start` в
`.text.reset` по `0xFFFF0000` (не более 128 байт) и `.text.trap` по `0xFFFF0080`.
Линкер выдаёт ошибку при нарушении reset/trap/stack границ. TCM/DDR ELF —
приложения для передачи управления из bootloader; hardware reset остаётся
`0xFFFF0000`. Скрипты не резервируют отдельную область под shared buffers:
будущая firmware должна явно разделить внутри carveout код/данные/descriptor.

## Debug без Linux: DPC и AXIS ILA

`jtag_axi` / JTAG-to-AXI Master **не поддерживается Versal**. Поэтому четвёртый
SmartConnect SI подключён к `CIPS/M_AXI_LPD`, а XSDB использует native DPC.
CIPS debug mode — JTAG. `create_hw_axi_txn`/`run_hw_axi` здесь не применяются.
Доступ требует загруженного соответствующего PDI, работающих CIPS/PLL и
снятого reset у SmartConnect/targets, но не Linux и не запущенного A72.

В Hardware Manager загрузи **новый** PDI и его LTX из того же routed run.
`axis_ila_scr1` — Versal AXIS ILA 1.2, Mixed, depth 1024, input pipeline 2.
Во время `opt_design` Vivado автоматически добавляет AXI Debug Hub + debug NoC
и соединяет их с CIPS (обычный non-DFX flow); проверь это в implementation log
и реализованной схеме. Отдельное MMIO-окно debug hub скрипт не создаёт вручную.

| ILA slot | AXI точка |
|---|---|
| 0 | A72 FPD → SmartConnect S00 |
| 1 | SmartConnect M01 → Control AXI-Lite |
| 2 | SmartConnect M02 → Boot AXI-Lite |
| 3 | GPIO S_AXI |
| 4 | DPC / LPD → SmartConnect S03 |
| 5 | SCR1 IMEM → SmartConnect S01, уже после alias translation |
| 6 | SCR1 DMEM → SmartConnect S02, уже после alias translation |

| Probe | Сигнал |
|---|---|
| 0 | PLL locked |
| 1 | CIPS pl0_resetn |
| 2 | interconnect_aresetn, в том числе SmartConnect reset |
| 3 | peripheral_aresetn, в том числе GPIO/RTL reset |
| 4 | readiness[2:0] |
| 5 | фактический CPU resetn SCR1 |
| 6 | lifecycle_state[3:0] |
| 7 | latched hardware AXI fault_code[3:0] |
| 8 | outstanding[11:0]: IMEM read / DMEM read / DMEM write, по 4 бита |

ILA тактируется тем же 90-МГц PLL. Его `resetn` подключён к constant 1,
чтобы захват оставался доступен при asserted functional reset. Если PLL clock
остановлен, этот ILA тоже не захватит данные; наличие clock проверяется отдельно.
Readiness GPIO управляет только readiness, не reset/clock своего AXI-пути.
Fault probe отражает AXI monitor; полный lifecycle FAULT_CODE читается в control.

Последовательность первого теста:

1. Загрузи PDI, подключи LTX, проверь обнаружение ILA и отсутствие debug hub errors.
2. Сделай immediate capture: locked=1, pl0_resetn=1, interconnect_aresetn=1,
   peripheral_aresetn=1. CPU resetn=0 и readiness=0 до старта SCR1 допустимы.
3. Arm ILA на slot 4 ARVALID (или slot 0 для Linux). Затем в XSDB:

   ```tcl
   connect -url tcp:127.0.0.1:3121
   targets
   targets <номер DPC из списка>
   source scripts/scripts/debug/scr1_dpc_smoke.tcl
   ```

   Скрипт выполняет только reads control, проверяет ID/90 МГц и печатает
   status/timeouts/fault/outstanding. Он не выполняет reset, LOAD, START или
   readiness writes. Ошибочный выбор target или неотвечающий AXI target может
   заблокировать `mrd`; аппаратного watchdog для самого debug transaction нет.
4. Для GPIO сначала arm на slot 3 ARVALID, затем один read `mrd 0x80020000`.
   Для контроля готовности нужно увидеть ARVALID/ARREADY, затем RVALID/RREADY
   с RRESP=OKAY. AR на slot 4 без AR на slot 3 указывает на decode/reset пути;
   AR handshake на slot 3 без RVALID — на clock/reset/ответ GPIO.
5. После успешного read можно проверить control SCRATCH0: сохрани
   `mrd -value 0x80000070`, запиши `mwr 0x80000070 0x12345678`, прочитай и
   восстанови сохранённое значение. Это не команда запуска SCR1.
6. Затем загрузи Linux с новым XSA/PDI и повтори наблюдение FPD slot 0 → slot 3
   для `0xA4020000`. Успех LPD-теста не доказывает работоспособность FPD-входа.
   При прежнем hang на probe GPIO временный `initcall_blacklist=xgpio_init`
   позволяет получить shell для debug, но не исправляет аппаратную причину.

Во всех slots доступны AW/W/B/AR/R. Для зависшего чтения запусти capture
достаточно рано: AR handshake может уже завершиться, пока Linux ждёт RVALID.
Для ошибочного SCR1 доступа смотри slot 5/6 response DECERR и fault/outstanding;
инструкции из normal Linux DDR не должны уходить в NoC.

## 1. Создание проекта, PDI и XSA (Vivado 2023.2)

Сначала сохрани предыдущий успешный проект и его PDI. Новый build по умолчанию
создаётся в `build/vivado-debug`, отдельно от старого `build/vivado`.
Повторное создание поверх существующего XPR запрещено; открывай существующий
проект либо выбирай новый `build_root` в `project_info.tcl`.

В каталоге репозитория:

```sh
vivado -mode batch -source scripts/scripts/vivado/create_project.tcl
vivado -mode batch -source scripts/scripts/vivado/build_device_image.tcl -tclargs build/vivado-debug/vd100_scr1/vd100_scr1.xpr build/hardware/cortix_scr1.xsa
```

Первый скрипт создаёт BD/wrapper, запускает synthesis и implementation до
`route_design`, формирует post-route timing/CDC/DRC/utilization reports и
останавливается с ошибкой при отрицательном setup/hold slack или Error DRC.
Второй продолжает успешный routed run до **Generate Device Image**
(`write_device_image`, Versal PDI), повторно квалифицирует результат и
экспортирует XSA и соответствующий `build/hardware/cortix_scr1.ltx`:

```tcl
write_hw_platform -fixed -include_bit build/hardware/cortix_scr1.xsa
```

Если PDI уже успешно получен в **новом Linux-проекте**, достаточно:

```sh
vivado -mode batch -source scripts/scripts/vivado/export_xsa.tcl -tclargs build/vivado-debug/vd100_scr1/vd100_scr1.xpr build/hardware/cortix_scr1.xsa
```

Экспорт отказывается от stale implementation, отсутствующего PDI/PLL/native
DDR routes, отрицательных setup/hold slack и Error DRC. Повторный экспорт не
перезаписывает существующий XSA: укажи новое имя. Дополнительно проверь отчёты
в `build/hardware/reports`: отсутствие необъяснённых unconstrained paths,
unsafe CDC, ошибки DDR pins и всех критических предупреждений.

## 2. PetaLinux 2023.2 из Cortix-XSA

Используй поддерживаемый PetaLinux Linux-host, **обычного пользователя** и
одинаковый релиз 2023.2 для Vivado/PetaLinux. Пример из каталога репозитория:

```sh
source /absolute/path/to/petalinux/2023.2/settings.sh
python3 scripts/scripts/linux/prepare_petalinux.py build/hardware/cortix_scr1.xsa build/petalinux-cortix
bash scripts/scripts/linux/build_sd.sh build/petalinux-cortix
```

`prepare_petalinux.py` создаёт новый template `versal`, импортирует ровно один
Cortix-XSA, применяет настройки SD/ext4 и наш минимальный device tree. Он не
перезаписывает существующий PetaLinux-проект и не использует старые ALINX
`system.xsa`, PDI, `BOOT.bin`, `image.ub` или host-specific offline paths.
Проверяются HWH-маркеры Cortix и наличие его PDI; это проверка идентичности,
не эквивалент hardware validation. SHA256 XSA сохраняется в handoff manifest.

Полная команда packaging для Versal:

```sh
petalinux-package --boot --format BIN --plm --psmfw --u-boot --dtb --force
```

Результат сборки: `build/petalinux-cortix/cortix-sd/`:

- `BOOT.BIN` — boot chain с **Cortix PDI**;
- `image.ub` — kernel/FIT;
- `boot.scr` — U-Boot boot script;
- `rootfs.tar.gz` — ext4 root filesystem;
- `handoff.json`, `SHA256SUMS` — идентичность XSA/образов.

Директория staging должна быть новой. Для повторной сборки сохрани/переименуй
старую `cortix-sd`, чтобы не смешивать поколения образов. Для offline builds
настрой cache/downloads в этом новом проекте под пути **своей** машины.

## 3. SD и контрольный Linux boot

Скрипты не форматируют и не записывают block devices. Используй уже проверенную
SD с разделами FAT32 `BOOT` и ext4 `ROOTFS` либо подготовь новую по ALINX guide.
Сначала сделай резервную копию: обновление файлов BOOT/rootfs заменяет систему.
Не выбирай `/dev/sdX` по догадке; проверь карту и её mountpoints через `lsblk -f`.

В Ubuntu, после проверки **конкретных** mountpoints:

```sh
payload=/absolute/path/to/repo/build/petalinux-cortix/cortix-sd
boot_mount=/absolute/mountpoint/of/SD/BOOT
rootfs_mount=/absolute/mountpoint/of/SD/ROOTFS
cd "$payload"
sha256sum -c SHA256SUMS
cp BOOT.BIN image.ub boot.scr "$boot_mount/"
sudo tar --numeric-owner -xzpf rootfs.tar.gz -C "$rootfs_mount/"
sync
```

На повторно используемой BOOT не оставляй отдельные старые `system.dtb`, `Image`
или другие boot images: U-Boot может выбрать их вместо нового FIT. Сохрани их
в backup вне BOOT. ROOTFS предпочтительно разворачивать на чистом ext4-разделе,
чтобы не остались старые конфиги/сервисы ALINX; форматирование требует отдельной
проверки выбранного устройства, не выполняется этими скриптами.

Безопасно извлеки SD, выставь SD boot mode по ALINX VD100 guide, вставь карту,
подключи UART (115200, 8N1, no flow control) и перезапусти питание платы.
Сохрани полный UART log от PLM до shell.

Конфигурация соответствует ALINX: eMMC на SD0, SD-карта на SD1,
rootfs `/dev/mmcblk1p2`. При `Waiting for root device` проверь фактическую
нумерацию в boot log и `printenv bootargs` в U-Boot; не обходи проблему
непроверенным старым `BOOT.bin`. Проверить размер RAM: 2 ГиБ DDR, 16 МиБ shared
region зарезервировано и не выдаётся Linux allocator.

Login `petalinux`, установи пароль при первом входе. Для root shell выполни
`sudo -i` (или используй уже настроенный root-пароль). Пустой root-пароль и
открытый SSH-root не включаются. Контрольная точка:

```text
root@petalinux:~#
```

После загрузки сохрани `uname -a`, `cat /proc/cmdline`, `lsblk -f`,
`dmesg | grep -Ei 'mmc|DDR|reserved|error|fail'`. Достижение этого shell с новыми
согласованными образами подтверждает Linux bring-up, но ещё не проверяет
bootloader/тесты SCR1. Доступ к PL MMIO проверяй после clock/reset readiness,
не делай слепой `devmem` в неотвечающий AXI target.

## Локальные regression checks

```sh
# Optional: enables actual SystemVerilog constant elaboration checks
python3 -m pip install pyslang==12.0.0
python3 scripts/scripts/checks/test_linux_integration.py
bash -n scripts/scripts/linux/build_sd.sh
```

Тесты исполняют production Tcl на **mock Vivado API** и проверяют per-SI
DDR/MMIO exclusions, LPD debug route, ILA slots/probes, частоты,
locked/reset, CIPS overlay, native NoC paths, карту адресов, Kconfig merge и
защитные отказы XSA export. Они не синтезируют IP, не заменяют Vivado и не
эмулируют реальную загрузку Versal. При установленном pyslang выполняются
реальная SV elaboration alias-функции/clock/timeout defaults и parsing RTL;
без пакета эта проверка явно помечается SKIP. При наличии cc/ld также
проверяются C header и linker success/overflow. Host linking не проверяет
исполнение RISC-V firmware.

## Источники

- [ALINX course_s2](https://github.com/alinxalinx/VD100_2023.2/tree/902446432c7d60a2968d96f8b02a7c57e00cc7e6/Demo/course_s2)
- [ALINX PetaLinux workflow](https://github.com/alinxalinx/VD100_2023.2/blob/902446432c7d60a2968d96f8b02a7c57e00cc7e6/Demo/course_s2/documentations/EN/2_About_PETALINUX.md)
- [AMD UG1144 2023.2: boot packaging](https://docs.amd.com/r/2023.2-English/ug1144-petalinux-tools-reference-guide/petalinux-package-boot-Examples)
- [AMD UG835 2023.2: write_hw_platform](https://docs.amd.com/r/2023.2-English/ug835-vivado-tcl-commands/write_hw_platform)


- [AMD UG908 2023.2: JTAG-to-AXI (Versal unsupported)](https://docs.amd.com/r/2023.2-English/ug908-vivado-programming-debugging/JTAG-to-AXI-Master)
- [AMD UG1388: DPC / XSDB AXI transactions](https://docs.amd.com/r/2023.1-English/ug1388-acap-system-integration-validation-methodology/Generating-AXI-Transactions)
- [AMD UG908 2023.2: automatic debug hub insertion](https://docs.amd.com/r/2023.2-English/ug908-vivado-programming-debugging/Adding-a-Control-Interface-and-Processing-System-CIPS)
- [AMD official Vivado 2023.2 Mixed AXIS ILA example](https://github.com/Xilinx/Vivado-Design-Tutorials/blob/2023.2/Device_Architecture_Tutorials/Versal/HW_Debug/Basic_HW_Debug/bd/base_design_complete.tcl)
