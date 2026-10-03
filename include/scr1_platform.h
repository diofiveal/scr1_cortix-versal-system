/* VD100 address/clock contract for future Linux drivers and SCR1 firmware.
 * Physical A72/DPC addresses and SCR1 aliases are intentionally different.
 * Linux must reserve shared DDR with no-map; no cache coherency is implied.
 * A Linux driver must take resources from DT and confirm IP_ID/HW_CONFIG.
 */
#ifndef VD100_SCR1_PLATFORM_H
#define VD100_SCR1_PLATFORM_H

#define SCR1_A72_CONTROL_BASE       0xA4000000UL
#define SCR1_A72_BOOT_BASE          0xA4010000UL
#define SCR1_A72_READY_GPIO_BASE    0xA4020000UL
#define SCR1_DPC_CONTROL_BASE       0x80000000UL
#define SCR1_DPC_BOOT_BASE          0x80010000UL
#define SCR1_DPC_READY_GPIO_BASE    0x80020000UL
#define SCR1_LOCAL_CONTROL_BASE     0xFF000000UL
#define SCR1_LOCAL_BOOT_BASE        0xFFFF0000UL
#define SCR1_CONTROL_BYTES          0x00001000UL
#define SCR1_BOOT_BYTES             0x00010000UL
#define SCR1_SHARED_DDR_BASE        0x7F000000UL
#define SCR1_SHARED_DDR_BYTES       0x01000000UL
#define SCR1_TCM_BASE               0xF0000000UL
#define SCR1_TCM_BYTES              0x00010000UL
#define SCR1_TIMER_BASE             0xF0040000UL
#define SCR1_RESET_VECTOR           SCR1_LOCAL_BOOT_BASE
#define SCR1_RESET_MTVEC            0xFFFF0080UL
#define SCR1_CLOCK_MHZ              90UL
#define SCR1_CLOCK_HZ               (SCR1_CLOCK_MHZ * 1000000UL)
#define SCR1_START_TIMEOUT_CYCLES   (SCR1_CLOCK_MHZ * 100000UL)
#define SCR1_QUIESCE_TIMEOUT_CYCLES (SCR1_CLOCK_MHZ * 1000UL)
#define SCR1_WATCHDOG_PERIOD_CYCLES (SCR1_CLOCK_MHZ * 1000000UL)
#define SCR1_IP_ID_EXPECTED         0x5343544CUL
#define SCR1_HWCFG_CLOCK_MHZ_MASK   0xFFUL

/* Local byte offsets, never absolute physical addresses. */
#define SCR1_REG_IP_ID                     0x000UL
#define SCR1_REG_IP_VERSION                0x004UL
#define SCR1_REG_CAPABILITIES              0x008UL
#define SCR1_REG_HW_CONFIG                 0x00CUL
#define SCR1_REG_CONTROL                   0x010UL
#define SCR1_REG_STATUS                    0x014UL
#define SCR1_REG_BOOT_ADDR                 0x018UL
#define SCR1_REG_FW_DESC_ADDR              0x01CUL
#define SCR1_REG_FW_DESC_SIZE              0x020UL
#define SCR1_REG_START_TOKEN               0x024UL
#define SCR1_REG_START_TIMEOUT             0x028UL
#define SCR1_REG_QUIESCE_TIMEOUT           0x02CUL
#define SCR1_REG_WATCHDOG_CFG              0x030UL
#define SCR1_REG_WATCHDOG_KICK             0x034UL
#define SCR1_REG_IRQ_STATUS                0x038UL
#define SCR1_REG_IRQ_ENABLE                0x03CUL
#define SCR1_REG_FAULT_CODE                0x040UL
#define SCR1_REG_FAULT_PC                  0x044UL
#define SCR1_REG_FAULT_INFO0               0x048UL
#define SCR1_REG_FAULT_INFO1               0x04CUL
#define SCR1_REG_OUTSTANDING               0x050UL
#define SCR1_REG_HEARTBEAT                 0x054UL
#define SCR1_REG_CYCLE_LO                  0x058UL
#define SCR1_REG_CYCLE_HI                  0x05CUL
#define SCR1_REG_BOOT_CRC_EXPECTED         0x060UL
#define SCR1_REG_BOOT_CRC_OBSERVED         0x064UL
#define SCR1_REG_SW_STATUS                 0x068UL
#define SCR1_REG_SW_ERROR                  0x06CUL
#define SCR1_REG_SCRATCH0                  0x070UL
#define SCR1_REG_SCRATCH1                  0x074UL
#define SCR1_REG_RESERVED_BASE             0x078UL

/* OUTSTANDING: [3:0] IMEM read, [7:4] DMEM read, [11:8] DMEM write. */
#define SCR1_OUTSTANDING_FIELD_MASK 0xFUL
#define SCR1_CONTROL_LOAD           0x01UL
#define SCR1_CONTROL_START          0x02UL
#define SCR1_CONTROL_QUIESCE        0x04UL
#define SCR1_CONTROL_HALT           0x08UL
#define SCR1_CONTROL_SOFT_RESET     0x10UL
#define SCR1_CONTROL_CLEAR_FAULT    0x20UL
#endif
