#include "menu_control.h"
#include "integration_service.h"
#include "gimbal_track.h"
#include "exposure_service.h"
#include <string.h>
const char *const menu_names[MENU_COUNT]={"AE","AG","GMR","BL","BO","MODE","P1","P2","P3","TRACK","AUTOEXP"};
/* Keep semantic IDs and the menu transport ABI; only visible navigation changes. */
static const uint8_t menu_order[]={MENU_MODE,MENU_EXPOSURE,MENU_AE,MENU_AG,
    MENU_BL,MENU_BO,MENU_P1,MENU_P2,MENU_P3,MENU_TRACK};
static int selectable(unsigned item) {
    return item<MENU_COUNT && item!=MENU_GMR &&
           (item!=MENU_TRACK || integration_get_mode()==0) &&
           (item!=MENU_P3 || integration_get_mode()!=2);
}
static unsigned move_selection(unsigned item,int next) {
    unsigned mode=integration_get_mode();
    unsigned count=mode==0?10u:mode==1?9u:8u;
    for(unsigned i=0;i<count;++i) if(menu_order[i]==item)
        return menu_order[next?(i+1)%count:(i+count-1)%count];
    return MENU_MODE;
}
void menu_init(Menu *m,uint32_t now) {
    memset(m,0,sizeof(*m));
    exposure_set_enabled(0);
    m->ae=1991;m->ag=190;m->gamma=MENU_GAMMA_FIXED_LEVEL;m->bl=1;m->bo=32;m->sf=MENU_SF_STRONG;
    m->rmin=100;m->rgap=65;m->bgap=65;gimbal_track_set_enabled(0);
    m->selected=MENU_MODE;
    m->stable=m->candidate=15;m->candidate_since=m->last_sample=now;
}
uint32_t menu_camera(const Menu *m) { return ((uint32_t)m->ag<<16)|m->ae; }
uint32_t menu_ui(const Menu *m) {
    unsigned selected=selectable(m->selected)?m->selected:MENU_MODE;
    return ((uint32_t)selected<<15)|((uint32_t)MENU_GAMMA_FIXED_LEVEL<<11)|
           ((uint32_t)m->bl<<10)|((uint32_t)m->bo<<2)|MENU_SF_STRONG;
}
uint32_t menu_rgb(const Menu *m) {
    return ((uint32_t)m->rmin<<16)|((uint32_t)m->rgap<<8)|m->bgap;
}
static unsigned clamp_step(unsigned value,unsigned low,unsigned high,unsigned step,int up) {
    if(up) return value+step>high?high:value+step;
    return value<low+step?low:value-step;
}
void menu_sample(Menu *m,uint8_t raw,uint32_t now) {
    m->gamma=MENU_GAMMA_FIXED_LEVEL;
    if(!selectable(m->selected)) {
        m->selected=MENU_MODE;m->held=0;m->wait_release=1;
        // Hidden TRACK or STYLE-retired P3 must not become a MODE adjustment while held.
        m->stable=m->candidate=raw&15u;m->candidate_since=now;
    }
    raw &= 15;
    if(m->wait_release) {
        m->stable=m->candidate=raw;m->candidate_since=m->last_sample=now;
        if(raw==15) m->wait_release=0;
        return;
    }
    // A sampling gap proves neither a release nor a new press. Preserve the
    // debounced level: resetting it to 15 would replay the same held key.
    // Restart candidate/repeat timing so unobserved time cannot debounce/repeat.
    if((uint32_t)(now-m->last_sample)>50) {
        m->candidate=raw;m->candidate_since=now;m->held=0;
        m->last_sample=now;return;
    }
    m->last_sample=now;
    uint8_t previous=m->stable;
    if(raw==m->stable) {m->candidate=raw;m->candidate_since=now;}
    else if(raw!=m->candidate) {m->candidate=raw;m->candidate_since=now;}
    else if((uint32_t)(now-m->candidate_since)>=20) m->stable=raw;
    unsigned pressed=(~m->stable)&15u,pulse=pressed&previous;
    unsigned item=m->selected;
    unsigned interval=item==MENU_AE?10u:item==MENU_AG?50u:250u;
    int held=!!(pressed&4)^!!(pressed&8),repeat=0;
    if(!held) m->held=0;
    else if(!m->held) {
        m->held=1;m->hold_since=now;m->repeat_since=now+500;
    } else if((uint32_t)(now-m->hold_since)>=500 &&
              (uint32_t)(now-m->repeat_since)>=interval) {
        repeat=1;m->repeat_since=now;
    }
    int up=((pulse&4)||repeat) && (pressed&4) && !(pressed&8);
    int down=((pulse&8)||repeat) && (pressed&8) && !(pressed&4);
    if(up || down) {
        switch(item) {
        case MENU_AE:exposure_set_enabled(0);m->ae=(uint16_t)clamp_step(m->ae,MENU_AE_MIN,MENU_AE_MAX,repeat?8:1,up);break;
        case MENU_AG:exposure_set_enabled(0);m->ag=(uint8_t)clamp_step(m->ag,MENU_AG_MIN,MENU_AG_MAX,1,up);break;
        case MENU_GMR:m->gamma=MENU_GAMMA_FIXED_LEVEL;break; // Read-only 0.70.
        case MENU_TRACK:gimbal_track_set_enabled(up);break;
        case MENU_EXPOSURE:exposure_set_enabled(up);break;
        case MENU_BL:m->bl=up?1:0;break;
        case MENU_BO:m->bo=(uint8_t)clamp_step(m->bo,0,255,1,up);break;
        case MENU_MODE: {
            uint32_t cur=integration_get_mode();
            if(up) cur=(cur+1)%3;
            else cur=(cur+2)%3;
            integration_set_mode(cur);
            break;
        }
        case MENU_P1: {
            uint32_t cur=integration_get_mode();
            if(cur==0) m->rmin=(uint8_t)clamp_step(m->rmin,0,255,1,up);
            else integration_adjust_param(0,up?1:-1);
            break;
        }
        case MENU_P2: {
            uint32_t cur=integration_get_mode();
            if(cur==0) m->rgap=(uint8_t)clamp_step(m->rgap,0,255,1,up);
            else integration_adjust_param(1,up?1:-1);
            break;
        }
        case MENU_P3: {
            uint32_t cur=integration_get_mode();
            if(cur==0) m->bgap=(uint8_t)clamp_step(m->bgap,0,255,1,up);
            else integration_adjust_param(2,up?1:-1);
            break;
        }
        }
    }
    // Like the RTL, simultaneous navigation/adjustment adjusts the old item.
    if((pulse&1) && !(pulse&2)) m->selected=(uint8_t)move_selection(item,0);
    else if((pulse&2) && !(pulse&1)) m->selected=(uint8_t)move_selection(item,1);
}
static int blank(char c) {return c==' ' || c=='\t';}
int menu_command(Menu *m,const char *line,uint32_t now) {
    while(blank(*line)) ++line;
    size_t length=strlen(line);
    while(length && blank(line[length-1])) --length;
    if(length==8 && !strncmp(line,"defaults",8)) {menu_init(m,now);return 1;}
    int select=length>=7 && !strncmp(line,"select",6) && blank(line[6]);
    int value=length>=6 && !strncmp(line,"value",5) && blank(line[5]);
    if(!select && !value) return 0;
    const char *p=line+(select?6:5),*end=line+length;
    while(p<end && blank(*p)) ++p;
    const char *name=p;while(p<end && !blank(*p)) ++p;
    unsigned item;
    for(item=0;item<MENU_COUNT;++item)
        if(strlen(menu_names[item])==(size_t)(p-name) && !strncmp(name,menu_names[item],p-name)) break;
    if(item==MENU_COUNT) {
        if(!strncmp(name,"SF",p-name) && (p-name)==2) item=MENU_MODE;
        else if(!strncmp(name,"RMIN",p-name) && (p-name)==4) item=MENU_P1;
        else if(!strncmp(name,"RGAP",p-name) && (p-name)==4) item=MENU_P2;
        else if(!strncmp(name,"BGAP",p-name) && (p-name)==4) item=MENU_P3;
        else return -1;
    }
    if(select) {
        if(p!=end)return -1;
        if(item==MENU_GMR)return -2;
        if(!selectable(item))return -1;
        m->selected=(uint8_t)item;return 1;
    }
    while(p<end && blank(*p)) ++p;
    if(p==end || *p<'0' || *p>'9') return -1;
    unsigned n=0;
    do { n=n*10u+(unsigned)(*p++-'0');if(n>3982)return -1; }
    while(p<end && *p>='0' && *p<='9');
    if(p!=end) return -1;
    switch(item) {
    case MENU_AE:if(n<MENU_AE_MIN || n>MENU_AE_MAX)return -1;exposure_set_enabled(0);m->ae=(uint16_t)n;break;
    case MENU_AG:if(n<MENU_AG_MIN || n>MENU_AG_MAX)return -1;exposure_set_enabled(0);m->ag=(uint8_t)n;break;
    case MENU_GMR:if(n!=MENU_GAMMA_FIXED_HUNDREDTHS)return -2;m->gamma=MENU_GAMMA_FIXED_LEVEL;break;
    case MENU_TRACK:if(n>1 || !g_track.supported || integration_get_mode()!=0)return -1;gimbal_track_set_enabled(n);break;
    case MENU_EXPOSURE:if(n>1 || !exposure_set_enabled(n))return -1;break;
    case MENU_BL:if(n>1)return -1;m->bl=(uint8_t)n;break;
    case MENU_BO:if(n>255)return -1;m->bo=(uint8_t)n;break;
    case MENU_MODE:if(n>2)return -1;integration_set_mode(n);break;
    case MENU_P1:
        if(integration_get_mode()==0) {if(n>255)return -1;m->rmin=(uint8_t)n;}
        break;
    case MENU_P2:
        if(integration_get_mode()==0) {if(n>255)return -1;m->rgap=(uint8_t)n;}
        break;
    case MENU_P3:
        if(integration_get_mode()==2)return -1;
        if(integration_get_mode()==0) {if(n>255)return -1;m->bgap=(uint8_t)n;}
        break;
    }
    return 1;
}
