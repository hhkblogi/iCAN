/*
 * error.h — CAN error frame definitions.
 *
 * Modeled after Linux SocketCAN: include/uapi/linux/can/error.h
 * Error frames use CAN_ERR_FLAG in can_id; data[] carries details.
 */

#pragma once

#include <stdint.h>

/* ================================================================
 * Error class bits (in can_id when CAN_ERR_FLAG is set)
 * ================================================================ */

#define CAN_ERR_TX_TIMEOUT  0x00000001U  /* TX timeout */
#define CAN_ERR_LOSTARB     0x00000002U  /* lost arbitration / data[0] */
#define CAN_ERR_CRTL        0x00000004U  /* controller problems / data[1] */
#define CAN_ERR_PROT        0x00000008U  /* protocol violations / data[2..3] */
#define CAN_ERR_TRX         0x00000010U  /* transceiver status / data[4] */
#define CAN_ERR_ACK         0x00000020U  /* received no ACK on transmission */
#define CAN_ERR_BUSOFF      0x00000040U  /* bus off */
#define CAN_ERR_BUSERROR    0x00000080U  /* bus error (bit, form, stuff, etc.) */
#define CAN_ERR_RESTARTED   0x00000100U  /* controller restarted */
#define CAN_ERR_CNT         0x00000200U  /* error counters available / data[6..7] */

/* ================================================================
 * Controller status (data[1] when CAN_ERR_CRTL is set)
 * ================================================================ */

#define CAN_ERR_CRTL_UNSPEC      0x00  /* unspecified */
#define CAN_ERR_CRTL_RX_OVERFLOW 0x01  /* RX buffer overflow */
#define CAN_ERR_CRTL_TX_OVERFLOW 0x02  /* TX buffer overflow */
#define CAN_ERR_CRTL_RX_WARNING  0x04  /* reached warning level (RX) */
#define CAN_ERR_CRTL_TX_WARNING  0x08  /* reached warning level (TX) */
#define CAN_ERR_CRTL_RX_PASSIVE  0x10  /* reached error passive (RX) */
#define CAN_ERR_CRTL_TX_PASSIVE  0x20  /* reached error passive (TX) */
#define CAN_ERR_CRTL_ACTIVE      0x40  /* recovered to error active */

/* ================================================================
 * Protocol error type (data[2] when CAN_ERR_PROT is set)
 * ================================================================ */

#define CAN_ERR_PROT_UNSPEC      0x00  /* unspecified */
#define CAN_ERR_PROT_BIT         0x01  /* single bit error */
#define CAN_ERR_PROT_FORM        0x02  /* frame format error */
#define CAN_ERR_PROT_STUFF       0x04  /* bit stuffing error */
#define CAN_ERR_PROT_BIT0        0x08  /* unable to send dominant bit */
#define CAN_ERR_PROT_BIT1        0x10  /* unable to send recessive bit */
#define CAN_ERR_PROT_OVERLOAD    0x20  /* bus overload */
#define CAN_ERR_PROT_ACTIVE      0x40  /* active error announcement */
#define CAN_ERR_PROT_TX          0x80  /* error occurred on TX */

/* Protocol error location (data[3] when CAN_ERR_PROT is set) */
#define CAN_ERR_PROT_LOC_UNSPEC  0x00  /* unspecified */
#define CAN_ERR_PROT_LOC_SOF     0x03  /* start of frame */
#define CAN_ERR_PROT_LOC_ID28_21 0x02  /* ID bits 28-21 (SFF: 10-3) */
#define CAN_ERR_PROT_LOC_ID20_18 0x06  /* ID bits 20-18 (SFF: 2-0) */
#define CAN_ERR_PROT_LOC_SRTR    0x04  /* substitute RTR (SFF: RTR) */
#define CAN_ERR_PROT_LOC_IDE     0x05  /* identifier extension */
#define CAN_ERR_PROT_LOC_ID17_13 0x07  /* ID bits 17-13 */
#define CAN_ERR_PROT_LOC_ID12_05 0x0F  /* ID bits 12-5 */
#define CAN_ERR_PROT_LOC_ID04_00 0x0E  /* ID bits 4-0 */
#define CAN_ERR_PROT_LOC_RTR     0x0C  /* RTR */
#define CAN_ERR_PROT_LOC_RES1    0x0D  /* reserved bit 1 */
#define CAN_ERR_PROT_LOC_RES0    0x09  /* reserved bit 0 */
#define CAN_ERR_PROT_LOC_DLC     0x0B  /* data length code */
#define CAN_ERR_PROT_LOC_DATA    0x0A  /* data section */
#define CAN_ERR_PROT_LOC_CRC_SEQ 0x08  /* CRC sequence */
#define CAN_ERR_PROT_LOC_CRC_DEL 0x18  /* CRC delimiter */
#define CAN_ERR_PROT_LOC_ACK     0x19  /* ACK slot */
#define CAN_ERR_PROT_LOC_ACK_DEL 0x1B  /* ACK delimiter */
#define CAN_ERR_PROT_LOC_EOF     0x1A  /* end of frame */
#define CAN_ERR_PROT_LOC_INTERM  0x12  /* intermission */

/* ================================================================
 * Transceiver status (data[4] when CAN_ERR_TRX is set)
 * ================================================================ */

#define CAN_ERR_TRX_UNSPEC            0x00
#define CAN_ERR_TRX_CANH_NO_WIRE     0x04
#define CAN_ERR_TRX_CANH_SHORT_TO_BAT 0x05
#define CAN_ERR_TRX_CANH_SHORT_TO_VCC 0x06
#define CAN_ERR_TRX_CANH_SHORT_TO_GND 0x07
#define CAN_ERR_TRX_CANL_NO_WIRE     0x40
#define CAN_ERR_TRX_CANL_SHORT_TO_BAT 0x50
#define CAN_ERR_TRX_CANL_SHORT_TO_VCC 0x60
#define CAN_ERR_TRX_CANL_SHORT_TO_GND 0x70
#define CAN_ERR_TRX_CANL_SHORT_TO_CANH 0x80

/* ================================================================
 * Error thresholds
 * ================================================================ */

#define CAN_ERROR_WARNING_THRESHOLD  96   /* error-warning state */
#define CAN_ERROR_PASSIVE_THRESHOLD  128  /* error-passive state */
#define CAN_BUS_OFF_THRESHOLD        256  /* bus-off state */
