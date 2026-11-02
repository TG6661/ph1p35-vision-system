#ifndef OOP_MENU_CONTROL_H
#define OOP_MENU_CONTROL_H
#include <stdint.h>
enum menu_item { MENU_AE, MENU_AG, MENU_GMR, MENU_BL, MENU_BO, MENU_MODE,
                 MENU_P1, MENU_P2, MENU_P3, MENU_TRACK, MENU_EXPOSURE, MENU_COUNT };
#define MENU_SF   MENU_MODE
#define MENU_RMIN MENU_P1
#define MENU_RGAP MENU_P2
#define MENU_BGAP MENU_P3
/* SF field/ABI is retained; only STRONG is implemented. */
enum { MENU_SF_STRONG = 3 };
/* RED Gamma is fixed in RTL; preserve the legacy level field and menu slot. */
enum { MENU_GAMMA_FIXED_LEVEL = 6, MENU_GAMMA_FIXED_HUNDREDTHS = 70 };
enum { MENU_AE_MIN = 2, MENU_AE_MAX = 1991, MENU_AG_MIN = 16, MENU_AG_MAX = 239 };
typedef struct {
    uint16_t ae;
    uint8_t ag,gamma,bl,bo,sf,rmin,rgap,bgap,selected;
    uint8_t stable,candidate,held,wait_release;
    uint32_t candidate_since,hold_since,repeat_since,last_sample;
} Menu;
extern const char *const menu_names[MENU_COUNT];
void menu_init(Menu *m,uint32_t now);
/* Sample actual elapsed time; caller must not replay missed samples. */
void menu_sample(Menu *m,uint8_t raw,uint32_t now);
uint32_t menu_camera(const Menu *m);
uint32_t menu_ui(const Menu *m);
uint32_t menu_rgb(const Menu *m);
/* 1 handled, 0 not this command, -1 malformed/range, -2 fixed GMR value. */
int menu_command(Menu *m,const char *line,uint32_t now);
#endif
