/* Integer equivalent of target_shape_classifier_v2 and target_tracker.
 * One update per accepted detection snapshot, never per display refresh. */
#include "target_processing.h"
#include <string.h>

void target_tracker_init(TargetTracker *s) {
    memset(s,0,sizeof(*s));s->next_id=1;
}
void target_tracker_forget(TargetTracker *s) {
    s->active=0;memset(s->missed,0,sizeof(s->missed));
}
void target_classify(Target *t) {
    t->shape=0;
    t->geometry_error=t->xmin>t->xmax || t->ymin>t->ymax || t->xmax>=1280 || t->ymax>=720;
    if(t->geometry_error) return;
    uint32_t w=(uint32_t)t->xmax-t->xmin+1,h=(uint32_t)t->ymax-t->ymin+1,box=w*h;
    t->geometry_error=t->area==0 || t->area>box;
    if(t->geometry_error || w<8 || h<8) return;
    uint32_t a100=100u*t->area;
    if(a100>=90u*box) t->shape=1;
    else if(10u*w>=9u*h && 10u*w<=11u*h && a100>=72u*box && a100<=85u*box) t->shape=2;
}
static unsigned delta(unsigned a,unsigned b) {return a>=b?a-b:b-a;}
static unsigned cx(const Target *t) {return ((unsigned)t->xmin+t->xmax)/2;}
static unsigned cy(const Target *t) {return ((unsigned)t->ymin+t->ymax)/2;}
static uint8_t next_id(uint8_t n) {return n==255?1:(uint8_t)(n+1);}

void target_process(TargetTracker *s,const TargetSnapshot *in,TargetSnapshot *out) {
    Target det[TARGET_CAPACITY];
    memset(out,0,sizeof(*out));
    out->sequence=in->sequence;out->frame_id=in->frame_id;out->dropped=in->dropped;
    out->total=in->total;out->error=in->error;
    if(in->count>TARGET_CAPACITY) out->error|=8;
    unsigned n=in->count>TARGET_CAPACITY?TARGET_CAPACITY:in->count;
    for(unsigned d=0;d<n;++d) {
        det[d]=in->items[d];target_classify(&det[d]);
        if(det[d].geometry_error) out->error|=8;
    }
    if(out->error) {target_tracker_forget(s);return;}
    unsigned matched=0,used=0;
    /* Global greedy matching. Strict < retains slot then detection tie order.
     * At most eight matches plus a final 8x8 search: bounded, no allocation. */
    for(unsigned pass=0;pass<=TARGET_CAPACITY;++pass) {
        unsigned best=4095,bt=TARGET_CAPACITY,bd=0;
        for(unsigned t=0;t<TARGET_CAPACITY;++t) {
            if(!(s->active&(1u<<t)) || (matched&(1u<<t))) continue;
            const Target *a=&s->slots[t];
            unsigned aw=a->xmax-a->xmin+1,ah=a->ymax-a->ymin+1;
            for(unsigned d=0;d<n;++d) {
                if(used&(1u<<d)) continue;
                const Target *b=&det[d];
                unsigned bw=b->xmax-b->xmin+1,bh=b->ymax-b->ymin+1;
                unsigned distance=delta(cx(a),cx(b))+delta(cy(a),cy(b));
                if(distance>96 || aw>2*bw || bw>2*aw || ah>2*bh || bh>2*ah) continue;
                unsigned cost=distance+((a->shape && b->shape && a->shape!=b->shape)?32u:0u);
                if(cost<best) {best=cost;bt=t;bd=d;}
            }
        }
        if(bt==TARGET_CAPACITY) break;
        uint8_t id=s->slots[bt].id,shape=s->slots[bt].shape;
        s->slots[bt]=det[bd];s->slots[bt].id=id;
        if(!det[bd].shape) s->slots[bt].shape=shape;
        s->missed[bt]=0;matched|=1u<<bt;used|=1u<<bd;
    }
    for(unsigned t=0;t<TARGET_CAPACITY;++t) if((s->active&(1u<<t)) && !(matched&(1u<<t))) {
        if(s->missed[t]>=2) s->active&=(uint8_t)~(1u<<t);
        else ++s->missed[t];
    }
    for(unsigned d=0;d<n;++d) if(!(used&(1u<<d))) {
        unsigned slot=TARGET_CAPACITY,oldest=0;
        for(unsigned t=0;t<TARGET_CAPACITY;++t) if(!(s->active&(1u<<t))) {slot=t;break;}
        if(slot==TARGET_CAPACITY) for(unsigned t=0;t<TARGET_CAPACITY;++t)
            if(!(matched&(1u<<t)) && (slot==TARGET_CAPACITY || s->missed[t]>oldest)) {
                slot=t;oldest=s->missed[t];
            }
        if(slot==TARGET_CAPACITY) continue;
        for(unsigned tries=0;tries<=TARGET_CAPACITY;++tries) {
            unsigned collision=0;
            for(unsigned t=0;t<TARGET_CAPACITY;++t)
                if((s->active&(1u<<t)) && s->slots[t].id==s->next_id) collision=1;
            if(!collision) break;
            s->next_id=next_id(s->next_id);
        }
        s->slots[slot]=det[d];s->slots[slot].id=s->next_id;s->next_id=next_id(s->next_id);
        s->active|=(uint8_t)(1u<<slot);s->missed[slot]=0;matched|=1u<<slot;
    }
    for(unsigned t=0;t<TARGET_CAPACITY;++t) if(matched&(1u<<t)) out->items[out->count++]=s->slots[t];
}
uint32_t target_pack_low(const Target *t) {
    return ((uint32_t)(t->xmin&1u)<<31)|((uint32_t)t->xmax<<20)|((uint32_t)t->ymin<<10)|t->ymax;
}
uint32_t target_pack_high(const Target *t) {
    return ((uint32_t)t->id<<12)|((uint32_t)t->shape<<10)|(t->xmin>>1);
}
