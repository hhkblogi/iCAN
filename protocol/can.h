/*
 * can.h — CAN standard frame types and helpers.
 *
 * Modeled after Linux SocketCAN: include/uapi/linux/can.h
 * Pure C header — no project-specific IPC or implementation details.
 */

#pragma once

#include <stdint.h>
#include <stdbool.h>

/* ================================================================
 * CAN identifier type and flag bits
 * ================================================================ */

typedef uint32_t canid_t;
typedef uint32_t can_err_mask_t;

/* canid_t flag bits (upper 3 bits) */
#define CAN_EFF_FLAG  0x80000000U   /* extended frame format (29-bit ID) */
#define CAN_RTR_FLAG  0x40000000U   /* remote transmission request */
#define CAN_ERR_FLAG  0x20000000U   /* error message frame */

/* ID masks */
#define CAN_SFF_MASK  0x000007FFU   /* standard frame: 11-bit ID */
#define CAN_EFF_MASK  0x1FFFFFFFU   /* extended frame: 29-bit ID */
#define CAN_ERR_MASK  0x1FFFFFFFU   /* error frame: omit EFF/RTR/ERR flags */

/* ================================================================
 * CAN frame structures
 * ================================================================ */

/* Data length limits */
#define CAN_MAX_DLEN   8    /* classic CAN max payload */
#define CANFD_MAX_DLEN 64   /* CAN FD max payload */

/* CAN FD flags (in canfd_frame.flags) */
#define CANFD_BRS  0x01   /* bit rate switch */
#define CANFD_ESI  0x02   /* error state indicator */
#define CANFD_FDF  0x04   /* FD frame format */

/* Classic CAN frame — 16 bytes, matches Linux struct can_frame layout */
struct can_frame {
    canid_t can_id;             /* CAN ID + EFF/RTR/ERR flags */
    uint8_t len;                /* payload length (0..8) */
    uint8_t __pad;
    uint8_t __res0;             /* used: channel number (CAN_CHANNEL macro) */
    uint8_t __res1;
    uint8_t data[CAN_MAX_DLEN] __attribute__((aligned(8)));
};

/* CAN FD frame — 72 bytes, matches Linux struct canfd_frame layout */
struct canfd_frame {
    canid_t can_id;             /* CAN ID + EFF/RTR/ERR flags */
    uint8_t len;                /* payload length (0..64) */
    uint8_t flags;              /* CANFD_BRS | CANFD_ESI | CANFD_FDF */
    uint8_t __res0;             /* used: channel number (CAN_CHANNEL macro) */
    uint8_t __res1;
    uint8_t data[CANFD_MAX_DLEN] __attribute__((aligned(8)));
};

/* Frame MTU constants */
#define CAN_MTU    sizeof(struct can_frame)      /* 16 */
#define CANFD_MTU  sizeof(struct canfd_frame)     /* 72 */

/* ================================================================
 * CAN FD DLC ↔ length conversion helpers
 * ================================================================ */

static inline uint8_t can_fd_dlc2len(uint8_t dlc) {
    static const uint8_t dlc2len[] = {0,1,2,3,4,5,6,7,8,12,16,20,24,32,48,64};
    return dlc < 16 ? dlc2len[dlc] : 64;
}

static inline uint8_t can_fd_len2dlc(uint8_t len) {
    if (len <= 8) return len;
    if (len <= 12) return 9;
    if (len <= 16) return 10;
    if (len <= 20) return 11;
    if (len <= 24) return 12;
    if (len <= 32) return 13;
    if (len <= 48) return 14;
    return 15;
}

/* ================================================================
 * CAN channel accessor — uses __res0 field to carry channel number.
 * Matches SavvyCAN CANFrame.bus pattern. SocketCAN layout preserved.
 * ================================================================ */

#define CAN_CHANNEL(frame)  ((frame).__res0)

/* ================================================================
 * CAN protocol identifiers
 * ================================================================ */

enum CANProtocol {
    kCANProtocolSLCAN = 1,
    kCANProtocolGSUSB = 2,
    kCANProtocolPCAN  = 3,
};
