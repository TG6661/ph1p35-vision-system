#ifndef MENU_TRANSPORT_H
#define MENU_TRANSPORT_H
#include "menu_control.h"
enum { TRANS_RESET=1, TRANS_MENU_ACK=2, TRANS_RGB_APPLIED=4,
       TRANS_RGB_WAIT=8, TRANS_REJECT=16 };
typedef struct {
    uint32_t camera,ui,rgb,menu_seq,rgb_seq,rgb_start;
    unsigned menu_pending,rgb_pending,menu_sent,rgb_sent,warned;
} MenuTransport;
void menu_transport_init(MenuTransport *t);
unsigned menu_transport_service(MenuTransport *t,Menu *m,uint32_t now);
#endif
