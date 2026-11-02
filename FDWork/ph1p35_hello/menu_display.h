#ifndef OOP_MENU_DISPLAY_H
#define OOP_MENU_DISPLAY_H
#include <stdint.h>
typedef struct {uint32_t words[3],sequence;uint8_t pending,sent;} MenuDisplay;
void menu_display_init(MenuDisplay *s);
void menu_display_pack(uint32_t camera,uint32_t ui,uint32_t rgb,uint32_t words[3]);
void menu_display_poll(MenuDisplay *s);
void menu_display_pack_mode(uint32_t camera,uint32_t ui,uint32_t mode,uint32_t p1,uint32_t p2,uint32_t p3,uint32_t words[3]);
#endif
