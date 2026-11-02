#include "gimbal_track.h"
#include "fabric_regs.h"
#include "integration_service.h"
/* Share main.c UART queue; console_uart.h contains TU-local state. */
static void (*logger)(const char *,...);
void gimbal_track_set_logger(void (*fn)(const char *,...)) {logger=fn;}
#define console_printf(...) do {if(logger) logger(__VA_ARGS__);} while(0)
#include <string.h>
GimbalTrack g_track;
enum { STALE_MS=500 };
static const uint16_t low[2]={600,800},high[2]={2400,2200};
static int32_t clamp(int32_t v,int32_t lo,int32_t hi) {return v<lo?lo:v>hi?hi:v;}
static void clear_controller(void) {
    g_track.has_target=0;g_track.patrol_active=0;
    for(unsigned a=0;a<2;++a) {g_track.previous[a]=0;g_track.dead[a]=0;}
}
static void hold_active(void) {
    g_track.dirty=0;
    if(!g_track.supported) return;
    REG_SERVO_CONTROL=SERVO_CANCEL|SERVO_CLEAR_REJECT;fabric_fence();
    uint32_t active=REG_SERVO_ACTIVE;
    g_track.wanted[0]=(uint16_t)(active&4095u);
    g_track.wanted[1]=(uint16_t)((active>>12)&4095u);
    for(unsigned a=0;a<2;++a) g_track.position[a]=(int32_t)g_track.wanted[a]*1000;
}
void gimbal_track_invalidate(void) {
    clear_controller();g_track.armed=0;g_track.have_sequence=0;
    // A mode/generation change cancels un-applied auto moves. Manual moves are
    // independent of the image mode and keep their own pending request.
    if(g_track.mode) hold_active();
}
void gimbal_track_init(void) {
    memset(&g_track,0,sizeof(g_track));
    g_track.kp[0]=35;g_track.kp[1]=35;g_track.kd[0]=20;g_track.kd[1]=20;
    g_track.step[0]=10000;g_track.step[1]=10000;
    g_track.inner[0]=20;g_track.outer[0]=35;
    g_track.inner[1]=20;g_track.outer[1]=35;
    g_track.patrol_step=16000; // 16us per fresh detection snapshot; rate follows detector updates.
    g_track.patrol_min=900;
    g_track.patrol_max=2100;
    g_track.patrol_dir=0;
    fabric_fence();g_track.supported=(REG_SERVO_ABI==SERVO_ABI);
    g_track.wanted[0]=g_track.wanted[1]=1500;
    g_track.position[0]=g_track.position[1]=1500000;
    hold_active(); // Default OFF; reset hardware emits centered pulses.
}
void gimbal_track_set_mode(unsigned mode) {
    if(mode>1) mode=1;
    if(!g_track.supported) mode=0;
    if((uint8_t)mode==g_track.mode) return;
    hold_active();clear_controller();g_track.armed=g_track.have_sequence=0;
    g_track.mode=(uint8_t)mode;
    g_track.enabled=(mode!=0);
    g_track.patrol_active=0; // Set only while a fresh empty snapshot drives a scan.
}
unsigned gimbal_track_mode(void) {return g_track.mode;}
void gimbal_track_set_enabled(unsigned enabled) {
    gimbal_track_set_mode(enabled?TRACK_MODE_ON:TRACK_MODE_OFF);
}
unsigned gimbal_track_enabled(void) {return g_track.mode!=0;}
static void flush_pair(void) {
    if(!g_track.supported || !g_track.dirty) return;
    fabric_fence();if(REG_SERVO_CONTROL&SERVO_BUSY) return;
    REG_SERVO_PAN=g_track.wanted[0];REG_SERVO_TILT=g_track.wanted[1];
    fabric_fence();REG_SERVO_CONTROL=SERVO_COMMIT|SERVO_CLEAR_REJECT;fabric_fence();
    // Read after commit drains the staged AHB write; rejected requests retry.
    if(!(REG_SERVO_CONTROL&SERVO_REJECTED)) g_track.dirty=0;
}
static void manual(unsigned pan,unsigned tilt) {
    gimbal_track_set_mode(0);hold_active();clear_controller();
    g_track.wanted[0]=(uint16_t)clamp((int32_t)pan,low[0],high[0]);
    g_track.wanted[1]=(uint16_t)clamp((int32_t)tilt,low[1],high[1]);
    for(unsigned a=0;a<2;++a) g_track.position[a]=(int32_t)g_track.wanted[a]*1000;
    g_track.dirty=1;flush_pair();
}
void gimbal_track_poll(const TargetService *ts,uint32_t now) {
    if(!g_track.supported) return;
    if(!g_track.mode) {flush_pair();return;}
    if(!integration_tracking_ready()) {
        if(g_track.armed) gimbal_track_invalidate();
        return;
    }
    if(!g_track.armed) {
        g_track.armed=1;g_track.have_sequence=ts->have_last;
        g_track.sequence=ts->last_sequence;clear_controller();return;
    }
    if(!ts->have_last || (uint32_t)(now-ts->last_ms)>=STALE_MS) {
        if(g_track.has_target || g_track.dirty || g_track.patrol_active) hold_active();
        clear_controller();return;
    }
    if(g_track.have_sequence && ts->last_sequence==g_track.sequence) {flush_pair();return;}
    if(g_track.have_sequence && ts->last_sequence!=g_track.sequence+1u) clear_controller();
    g_track.sequence=ts->last_sequence;g_track.have_sequence=1;
    const TargetSnapshot *snap=&ts->last;const Target *best=0;
    // Corrupt detections are not proof of an empty scene. Retain the old hold behavior.
    if(snap->error || snap->count>TARGET_CAPACITY) {hold_active();clear_controller();return;}
    for(unsigned i=0;i<snap->count;++i) {
        const Target *t=&snap->items[i];
        if(t->geometry_error || t->xmin>t->xmax || t->ymin>t->ymax ||
           t->xmax>=1280 || t->ymax>=720 || t->shape>2) {
            hold_active();clear_controller();return;
        }
    }
    if(snap->count<=TARGET_CAPACITY && !snap->error) for(unsigned i=0;i<snap->count;++i) {
        const Target *t=&snap->items[i];
        if(t->geometry_error || !t->area || t->xmin>t->xmax || t->ymin>t->ymax ||
           t->xmax>=1280 || t->ymax>=720 || t->shape>2) continue;
        if(!g_track.any_shape && t->shape!=2) continue;
        if(!best || t->area>best->area) best=t;
    }
    if(best) {
        g_track.patrol_active=0;
        int continuity=g_track.has_target && g_track.target_id==best->id;
        if(!continuity) clear_controller();
        int16_t error[2]={(int16_t)(((int32_t)best->xmin+best->xmax)/2-640),
                          (int16_t)(((int32_t)best->ymin+best->ymax)/2-360)};
        g_track.target_id=best->id;g_track.target_shape=best->shape;g_track.has_target=1;
        for(unsigned a=0;a<2;++a) {
            int32_t e=error[a],d=continuity?e-g_track.previous[a]:0,abs_e=e<0?-e:e;
            g_track.previous[a]=(int16_t)e;
            if(g_track.dead[a]) {if(abs_e>g_track.outer[a]) g_track.dead[a]=0;}
            else if(abs_e<=g_track.inner[a]) g_track.dead[a]=1;
            if(!g_track.dead[a]) {
                int32_t delta=g_track.kp[a]*e+g_track.kd[a]*d;
                if(a==0) delta=-delta;
                g_track.position[a]+=clamp(delta,-g_track.step[a],g_track.step[a]);
            }
            g_track.position[a]=clamp(g_track.position[a],(int32_t)low[a]*1000,(int32_t)high[a]*1000);
            uint16_t next=(uint16_t)(g_track.position[a]/1000);
            if(next!=g_track.wanted[a]) {g_track.wanted[a]=next;g_track.dirty=1;}
        }
        flush_pair();
        return;
    }
    // No red circle target detected in current frame
    if(g_track.mode==TRACK_MODE_PATROL) {
        clear_controller();
        g_track.patrol_active=1;
        // 1. Pan sweeping
        if(!g_track.patrol_dir) {
            g_track.position[0]+=g_track.patrol_step;
            if(g_track.position[0]>=(int32_t)g_track.patrol_max*1000) {
                g_track.position[0]=(int32_t)g_track.patrol_max*1000;
                g_track.patrol_dir=1;
            }
        } else {
            g_track.position[0]-=g_track.patrol_step;
            if(g_track.position[0]<=(int32_t)g_track.patrol_min*1000) {
                g_track.position[0]=(int32_t)g_track.patrol_min*1000;
                g_track.patrol_dir=0;
            }
        }
        g_track.position[0]=clamp(g_track.position[0],(int32_t)low[0]*1000,(int32_t)high[0]*1000);
        uint16_t next0=(uint16_t)(g_track.position[0]/1000);
        if(next0!=g_track.wanted[0]) {g_track.wanted[0]=next0;g_track.dirty=1;}

        // 2. Tilt centering (smoothly drift back to 1500us if tilted)
        int32_t tilt_err=1500000-g_track.position[1];
        if(tilt_err>1000 || tilt_err<-1000) {
            g_track.position[1]+=clamp(tilt_err,-g_track.step[1],g_track.step[1]);
            g_track.position[1]=clamp(g_track.position[1],(int32_t)low[1]*1000,(int32_t)high[1]*1000);
            uint16_t next1=(uint16_t)(g_track.position[1]/1000);
            if(next1!=g_track.wanted[1]) {g_track.wanted[1]=next1;g_track.dirty=1;}
        }
        flush_pair();
        return;
    }
    hold_active();clear_controller();
}
void gimbal_track_status(void) {
    uint32_t active=g_track.supported?REG_SERVO_ACTIVE:0;
    console_printf("[TRACK] hw=%u mode=%u (%s) patrol_active=%u red_ready=%u any_red=%u target=%u id=%u shape=%u pending=%u\r\n",
        (unsigned)g_track.supported,(unsigned)g_track.mode,
        g_track.mode==0?"OFF":"PATROL",
        (unsigned)g_track.patrol_active,
        (unsigned)integration_tracking_ready(),
        (unsigned)g_track.any_shape,(unsigned)g_track.has_target,(unsigned)g_track.target_id,
        (unsigned)g_track.target_shape,g_track.supported?(unsigned)(REG_SERVO_CONTROL&1u):0u);
    console_printf("wanted=%u/%u active=%u/%u us; kp=%ld/%ld kd=%ld/%ld step=%ld/%ld milli-us\r\n",
        (unsigned)g_track.wanted[0],(unsigned)g_track.wanted[1],(unsigned)(active&4095u),(unsigned)((active>>12)&4095u),
        (long)g_track.kp[0],(long)g_track.kp[1],(long)g_track.kd[0],(long)g_track.kd[1],
        (long)g_track.step[0],(long)g_track.step[1]);
    console_printf("patrol range=%u..%u us step=%ld milli-us dir=%u; deadband pan=%u/%u tilt=%u/%u px\r\n",
        (unsigned)g_track.patrol_min,(unsigned)g_track.patrol_max,(long)g_track.patrol_step,(unsigned)g_track.patrol_dir,
        (unsigned)g_track.inner[0],(unsigned)g_track.outer[0],(unsigned)g_track.inner[1],(unsigned)g_track.outer[1]);
}
void gimbal_track_help(void) {
    console_printf("TRACK menu: + PATROL / - OFF (default OFF, RED only). servo PAN TILT | pan N | tilt N (us)\r\n");
    console_printf("track patrol|off|reset|status (on aliases patrol) | track mode circle|any (red shapes only)\r\n");
    console_printf("track patrol [MIN MAX [STEP]]: pan us, STEP 1..100 us per fresh snapshot\r\n");
    console_printf("track kp|kd PAN [TILT] (0..1000, scale1000); track step PAN [TILT] (1..100us/update)\r\n");
    console_printf("track deadband INNER [OUTER] (tilt only, 0..360px, outer>inner); reset centers and disables\r\n");
}
static const char *spaces(const char *p) {while(*p==' ' || *p=='\t') ++p;return p;}
static int token(const char **p,const char *word) {
    const char *s=spaces(*p);unsigned n=(unsigned)strlen(word);
    if(strncmp(s,word,n) || (s[n] && s[n]!=' ' && s[n]!='\t')) return 0;
    *p=s+n;return 1;
}
static int number(const char **p,unsigned *out,unsigned limit) {
    const char *s=spaces(*p);unsigned n=0;
    if(*s<'0' || *s>'9') return 0;
    do {unsigned d=(unsigned)(*s++-'0');if(n>limit/10 || (n==limit/10 && d>limit%10)) return 0;n=n*10+d;}
    while(*s>='0' && *s<='9');
    if(*s && *s!=' ' && *s!='\t') return 0;
    *p=s;*out=n;return 1;
}
static int end(const char *p) {return !*spaces(p);}
int gimbal_track_command(const char *line) {
    const char *s=line;unsigned a,b;
    int pair=token(&s,"servo"),pan=0,tilt=0;
    if(!pair) pan=token(&s,"pan");
    if(!pair && !pan) tilt=token(&s,"tilt");
    if(pair || pan || tilt) {
        if(!number(&s,&a,65535)) return -1;
        b=a;if(pair && !number(&s,&b,65535)) return -1;
        if(!end(s) || !g_track.supported) return -1;
        manual(tilt?g_track.wanted[0]:a,pan?g_track.wanted[1]:b);
        gimbal_track_status();return 1;
    }
    if(!token(&s,"track")) return 0;
    if(end(s)) {gimbal_track_status();return 1;}
    if(token(&s,"status")) {if(!end(s))return -1;gimbal_track_status();return 1;}
    if(token(&s,"on")) {if(!end(s) || !g_track.supported)return -1;gimbal_track_set_mode(TRACK_MODE_ON);}
    else if(token(&s,"off")) {if(!end(s))return -1;gimbal_track_set_mode(TRACK_MODE_OFF);}
    else if(token(&s,"patrol") || token(&s,"ptrl") || token(&s,"scan")) {
        if(!g_track.supported) return -1;
        if(end(s)) {
            gimbal_track_set_mode(TRACK_MODE_PATROL);
        } else {
            if(!number(&s,&a,2500) || !number(&s,&b,2500)) return -1;
            if(a<low[0] || b>high[0] || a>=b) return -1;
            unsigned c=(unsigned)(g_track.patrol_step/1000);
            if(!end(s) && (!number(&s,&c,100) || !c || !end(s))) return -1;
            // Validate the complete command before changing any setting.
            g_track.patrol_min=(uint16_t)a;g_track.patrol_max=(uint16_t)b;
            g_track.patrol_step=(int32_t)c*1000;
            gimbal_track_set_mode(TRACK_MODE_PATROL);
        }
    }
    else if(token(&s,"reset")) {if(!end(s) || !g_track.supported)return -1;manual(1500,1500);}
    else if(token(&s,"mode")) {
        if(token(&s,"circle")) a=0;else if(token(&s,"any")) a=1;else return -1;
        if(!end(s)) return -1;
        g_track.any_shape=(uint8_t)a;gimbal_track_invalidate();
    } else {
        unsigned kind;
        if(token(&s,"kp")) kind=0;else if(token(&s,"kd")) kind=1;
        else if(token(&s,"step")) kind=2;else if(token(&s,"deadband")) kind=3;else return -1;
        unsigned limit=kind<2?1000:kind==2?100:360;
        if(!number(&s,&a,limit)) return -1;
        b=kind==3?a+20:a;
        if(!end(s) && !number(&s,&b,limit)) return -1;
        if(!end(s) || b>limit || (kind==2 && (!a || !b)) || (kind==3 && b<=a)) return -1;
        if(kind==0) {g_track.kp[0]=(int32_t)a;g_track.kp[1]=(int32_t)b;}
        if(kind==1) {g_track.kd[0]=(int32_t)a;g_track.kd[1]=(int32_t)b;}
        if(kind==2) {g_track.step[0]=(int32_t)a*1000;g_track.step[1]=(int32_t)b*1000;}
        if(kind==3) {g_track.inner[1]=(uint16_t)a;g_track.outer[1]=(uint16_t)b;}
        clear_controller();
    }
    gimbal_track_status();return 1;
}
