#include "integration_service.h"
#include <string.h>
typedef struct {
    uint8_t left;
    uint8_t right;
    uint8_t top;
    uint8_t bottom;
    uint16_t area;
    uint8_t valid;
} MotionBox_t;

typedef struct {
    uint8_t active;
    uint8_t left;
    uint8_t right;
    uint8_t top;
    uint8_t bottom;
    uint16_t area;
    int hold_timer;
    int hit_count;
} MotionTrack_t;

#define MAX_MOTION_TRACKS 4

// Teammate FPGA already applies its fixed +4-block Y calibration.
// This service adds only the user-controlled offset; retained by request.
#define MOTION_X_OFFSET_BLOCKS 0

static MotionTrack_t motion_tracks[MAX_MOTION_TRACKS];

static inline uint32_t pack_motion_box(uint8_t left, uint8_t right, uint8_t top, uint8_t bottom) {
    return ((uint32_t)(left & 0xFF) << 22) |
           ((uint32_t)(right & 0xFF) << 14) |
           ((uint32_t)(top & 0x7F) << 7) |
           ((uint32_t)(bottom & 0x7F));
}

static inline void unpack_motion_box(uint32_t packed, uint8_t *left, uint8_t *right, uint8_t *top, uint8_t *bottom) {
    *left   = (uint8_t)((packed >> 22) & 0xFF);
    *right  = (uint8_t)((packed >> 14) & 0xFF);
    *top    = (uint8_t)((packed >> 7) & 0x7F);
    *bottom = (uint8_t)(packed & 0x7F);
}


void motion_reset(void) {memset(motion_tracks,0,sizeof(motion_tracks));}
uint8_t motion_process(uint8_t raw_box_valid,const uint32_t raw_packed[4],unsigned motion_hold_frames,int motion_y_offset,uint32_t output[4]) {
    // 1. Unpack Raw Candidate Boxes from FPGA & Apply Spatial Calibration
    MotionBox_t cands[4];
    int cand_count = 0;
    for (int i = 0; i < 4; i++) {
        if (raw_box_valid & (1 << i)) {
            uint8_t raw_l, raw_r, raw_t, raw_b;
            unpack_motion_box(raw_packed[i], &raw_l, &raw_r, &raw_t, &raw_b);

            int adj_l = (int)raw_l + MOTION_X_OFFSET_BLOCKS;
            int adj_r = (int)raw_r + MOTION_X_OFFSET_BLOCKS;
            int adj_t = (int)raw_t + motion_y_offset;
            int adj_b = (int)raw_b + motion_y_offset;

            if (adj_l < 0) adj_l = 0;
            if (adj_l > 159) adj_l = 159;
            if (adj_r < 0) adj_r = 0;
            if (adj_r > 159) adj_r = 159;
            if (adj_t < 0) adj_t = 0;
            if (adj_t > 89) adj_t = 89;
            if (adj_b < 0) adj_b = 0;
            if (adj_b > 89) adj_b = 89;

            if (adj_r >= adj_l && adj_b >= adj_t) {
                uint16_t box_area = (uint16_t)((adj_r - adj_l + 1) * (adj_b - adj_t + 1));
                // Noise filter: Discard tiny isolated noise boxes (< 4 macroblocks or single 8x8 block)
                if (box_area < 4 || (adj_r == adj_l && adj_b == adj_t)) {
                    continue;
                }
                cands[cand_count].left = (uint8_t)adj_l;
                cands[cand_count].right = (uint8_t)adj_r;
                cands[cand_count].top = (uint8_t)adj_t;
                cands[cand_count].bottom = (uint8_t)adj_b;
                cands[cand_count].area = box_area;
                cands[cand_count].valid = 1;
                cand_count++;
            }
        }
    }

    // 2. Scheme 1 (Layer 1): Adaptive Multi-Box Spatial Clustering
    // Widen merge threshold to bridge slow-motion palm hollows (Gap_X <= 6, Gap_Y <= 7 blocks)
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < cand_count; i++) {
            if (!cands[i].valid) continue;
            for (int j = i + 1; j < cand_count; j++) {
                if (!cands[j].valid) continue;

                int gap_x = 0;
                if (cands[i].left > cands[j].right) gap_x = cands[i].left - cands[j].right - 1;
                else if (cands[j].left > cands[i].right) gap_x = cands[j].left - cands[i].right - 1;

                int gap_y = 0;
                if (cands[i].top > cands[j].bottom) gap_y = cands[i].top - cands[j].bottom - 1;
                else if (cands[j].top > cands[i].bottom) gap_y = cands[j].top - cands[i].bottom - 1;

                int merged_l = (cands[i].left < cands[j].left) ? cands[i].left : cands[j].left;
                int merged_r = (cands[i].right > cands[j].right) ? cands[i].right : cands[j].right;
                int merged_t = (cands[i].top < cands[j].top) ? cands[i].top : cands[j].top;
                int merged_b = (cands[i].bottom > cands[j].bottom) ? cands[i].bottom : cands[j].bottom;

                // Merge if fragments are within limb span (<=48px X, <=48px Y) and total size is reasonable
                if (gap_x <= 6 && gap_y <= 6 && (merged_r - merged_l) <= 70 && (merged_b - merged_t) <= 70) {
                    cands[i].left   = merged_l;
                    cands[i].right  = merged_r;
                    cands[i].top    = merged_t;
                    cands[i].bottom = merged_b;
                    cands[i].area   = (uint16_t)((cands[i].right - cands[i].left + 1) *
                                                 (cands[i].bottom - cands[i].top + 1));
                    cands[j].valid  = 0;
                }
            }
        }
    }

    // 3. Compact & Sort Candidates by Area (Descending)
    MotionBox_t sorted_cands[4];
    int sorted_count = 0;
    for (int i = 0; i < cand_count; i++) {
        if (cands[i].valid) {
            sorted_cands[sorted_count++] = cands[i];
        }
    }
    for (int i = 0; i < sorted_count - 1; i++) {
        for (int j = i + 1; j < sorted_count; j++) {
            if (sorted_cands[j].area > sorted_cands[i].area) {
                MotionBox_t tmp = sorted_cands[i];
                sorted_cands[i] = sorted_cands[j];
                sorted_cands[j] = tmp;
            }
        }
    }

    // 4. Scheme 1 (Layer 2): Track-Guided Split Absorption & Multi-Target Association
    uint8_t cand_assigned[4] = {0, 0, 0, 0};

    // Update active tracks with matching candidates (absorbing splits into historical envelope)
    for (int t = 0; t < MAX_MOTION_TRACKS; t++) {
        if (!motion_tracks[t].active) continue;

        // Expanded historical envelope (allows normal hand motion between frames)
        int env_l = (motion_tracks[t].left > 6) ? (motion_tracks[t].left - 6) : 0;
        int env_r = (motion_tracks[t].right + 6 < 160) ? (motion_tracks[t].right + 6) : 159;
        int env_t = (motion_tracks[t].top > 6) ? (motion_tracks[t].top - 6) : 0;
        int env_b = (motion_tracks[t].bottom + 6 < 90) ? (motion_tracks[t].bottom + 6) : 89;

        int matched_indices[4];
        int match_cnt = 0;

        for (int c = 0; c < sorted_count; c++) {
            if (cand_assigned[c]) continue;

            int c_cx = (sorted_cands[c].left + sorted_cands[c].right) / 2;
            int c_cy = (sorted_cands[c].top + sorted_cands[c].bottom) / 2;

            // Check if candidate center falls in envelope or candidate overlaps with envelope
            int in_env = (c_cx >= env_l && c_cx <= env_r && c_cy >= env_t && c_cy <= env_b) ||
                         (sorted_cands[c].left <= env_r && sorted_cands[c].right >= env_l &&
                          sorted_cands[c].top <= env_b && sorted_cands[c].bottom >= env_t);

            if (in_env) {
                matched_indices[match_cnt++] = c;
            }
        }

        if (match_cnt > 0) {
            // Find matched candidate closest to track historical center
            int t_cx = (motion_tracks[t].left + motion_tracks[t].right) / 2;
            int t_cy = (motion_tracks[t].top + motion_tracks[t].bottom) / 2;
            int best_m = 0;
            int min_dist = 999999;

            for (int m = 0; m < match_cnt; m++) {
                int idx = matched_indices[m];
                int c_cx = (sorted_cands[idx].left + sorted_cands[idx].right) / 2;
                int c_cy = (sorted_cands[idx].top + sorted_cands[idx].bottom) / 2;
                int dist = (t_cx - c_cx) * (t_cx - c_cx) + (t_cy - c_cy) * (t_cy - c_cy);
                if (dist < min_dist) {
                    min_dist = dist;
                    best_m = m;
                }
            }

            int chosen = matched_indices[best_m];
            uint8_t u_l = sorted_cands[chosen].left;
            uint8_t u_r = sorted_cands[chosen].right;
            uint8_t u_t = sorted_cands[chosen].top;
            uint8_t u_b = sorted_cands[chosen].bottom;
            cand_assigned[chosen] = 1;

            // Target Separation vs Fragment Absorption (Dual Criteria):
            // Only treat candidate as a separating target if it has independent target mass (area >= 12 blocks)
            // AND has pulled away beyond limb reach (gx > 6 || gy > 6 blocks = 48px).
            // All other fragments (small area < 12 or close gap <= 6) are absorbed into the single object.
            int any_split = 0;
            for (int m = 0; m < match_cnt; m++) {
                if (m == best_m) continue;
                int idx = matched_indices[m];

                int gx = 0, gy = 0;
                if (sorted_cands[idx].left > u_r) gx = sorted_cands[idx].left - u_r - 1;
                else if (sorted_cands[idx].right < u_l) gx = u_l - sorted_cands[idx].right - 1;

                if (sorted_cands[idx].top > u_b) gy = sorted_cands[idx].top - u_b - 1;
                else if (sorted_cands[idx].bottom < u_t) gy = u_t - sorted_cands[idx].bottom - 1;

                if (sorted_cands[idx].area >= 12 && (gx > 6 || gy > 6)) {
                    any_split = 1; // Genuine separate target! Leave unassigned so it spawns a separate track
                } else {
                    // Fragment / limb belonging to same object: absorb into bounding box
                    if (sorted_cands[idx].left < u_l) u_l = sorted_cands[idx].left;
                    if (sorted_cands[idx].right > u_r) u_r = sorted_cands[idx].right;
                    if (sorted_cands[idx].top < u_t) u_t = sorted_cands[idx].top;
                    if (sorted_cands[idx].bottom > u_b) u_b = sorted_cands[idx].bottom;
                    cand_assigned[idx] = 1;
                }
            }

            if (any_split) {
                // When separating, snap track immediately to chosen target to instantly collapse merged envelope
                motion_tracks[t].left   = u_l;
                motion_tracks[t].right  = u_r;
                motion_tracks[t].top    = u_t;
                motion_tracks[t].bottom = u_b;
            } else {
                // Smooth coordinates (75% old + 25% new) to eliminate jitter while maintaining full hand span
                motion_tracks[t].left   = (uint8_t)((motion_tracks[t].left * 3 + u_l) / 4);
                motion_tracks[t].right  = (uint8_t)((motion_tracks[t].right * 3 + u_r) / 4);
                motion_tracks[t].top    = (uint8_t)((motion_tracks[t].top * 3 + u_t) / 4);
                motion_tracks[t].bottom = (uint8_t)((motion_tracks[t].bottom * 3 + u_b) / 4);
            }
            motion_tracks[t].area   = (uint16_t)((motion_tracks[t].right - motion_tracks[t].left + 1) *
                                                 (motion_tracks[t].bottom - motion_tracks[t].top + 1));
            motion_tracks[t].hold_timer = motion_hold_frames;
            motion_tracks[t].hit_count++;
        } else {
            // Fallback: If target made a fast movement across the screen, search by center distance
            int best_c = -1;
            int min_dist = 9999;
            int t_cx = (motion_tracks[t].left + motion_tracks[t].right) / 2;
            int t_cy = (motion_tracks[t].top + motion_tracks[t].bottom) / 2;

            for (int c = 0; c < sorted_count; c++) {
                if (cand_assigned[c]) continue;
                int c_cx = (sorted_cands[c].left + sorted_cands[c].right) / 2;
                int c_cy = (sorted_cands[c].top + sorted_cands[c].bottom) / 2;
                int dist = (t_cx - c_cx) * (t_cx - c_cx) + (t_cy - c_cy) * (t_cy - c_cy);

                if (dist < 1200 && dist < min_dist) {
                    min_dist = dist;
                    best_c = c;
                }
            }

            if (best_c >= 0) {
                motion_tracks[t].left   = (uint8_t)((motion_tracks[t].left * 3 + sorted_cands[best_c].left) / 4);
                motion_tracks[t].right  = (uint8_t)((motion_tracks[t].right * 3 + sorted_cands[best_c].right) / 4);
                motion_tracks[t].top    = (uint8_t)((motion_tracks[t].top * 3 + sorted_cands[best_c].top) / 4);
                motion_tracks[t].bottom = (uint8_t)((motion_tracks[t].bottom * 3 + sorted_cands[best_c].bottom) / 4);
                motion_tracks[t].area   = (uint16_t)((motion_tracks[t].right - motion_tracks[t].left + 1) *
                                                     (motion_tracks[t].bottom - motion_tracks[t].top + 1));
                motion_tracks[t].hold_timer = motion_hold_frames;
                motion_tracks[t].hit_count++;
                cand_assigned[best_c] = 1;
            } else {
                // Unmatched: Hold countdown
                if (motion_tracks[t].hold_timer > 0) {
                    motion_tracks[t].hold_timer--;
                } else {
                    motion_tracks[t].active = 0; // Expired
                }
            }
        }
    }

    // Allocate unassigned candidates to inactive track slots
    for (int c = 0; c < sorted_count; c++) {
        if (cand_assigned[c]) continue;
        if (sorted_cands[c].area < 8) continue; // Noise rejection: ignore tiny floating fragments
        for (int t = 0; t < MAX_MOTION_TRACKS; t++) {
            if (!motion_tracks[t].active) {
                motion_tracks[t].active     = 1;
                motion_tracks[t].left       = sorted_cands[c].left;
                motion_tracks[t].right      = sorted_cands[c].right;
                motion_tracks[t].top        = sorted_cands[c].top;
                motion_tracks[t].bottom     = sorted_cands[c].bottom;
                motion_tracks[t].area       = sorted_cands[c].area;
                motion_tracks[t].hold_timer = motion_hold_frames;
                motion_tracks[t].hit_count  = 1;
                cand_assigned[c] = 1;
                break;
            }
        }
    }

    // 5. Post-Association Track Deduplication (Double safety against duplicate adjacent tracks)
    for (int i = 0; i < MAX_MOTION_TRACKS; i++) {
        if (!motion_tracks[i].active) continue;
        for (int j = i + 1; j < MAX_MOTION_TRACKS; j++) {
            if (!motion_tracks[j].active) continue;
            if (motion_tracks[i].left <= motion_tracks[j].right + 3 &&
                motion_tracks[i].right + 3 >= motion_tracks[j].left &&
                motion_tracks[i].top  <= motion_tracks[j].bottom + 3 &&
                motion_tracks[i].bottom + 3 >= motion_tracks[j].top) {
                // Merge track j into track i
                if (motion_tracks[j].left < motion_tracks[i].left) motion_tracks[i].left = motion_tracks[j].left;
                if (motion_tracks[j].right > motion_tracks[i].right) motion_tracks[i].right = motion_tracks[j].right;
                if (motion_tracks[j].top < motion_tracks[i].top) motion_tracks[i].top = motion_tracks[j].top;
                if (motion_tracks[j].bottom > motion_tracks[i].bottom) motion_tracks[i].bottom = motion_tracks[j].bottom;
                motion_tracks[i].area = (uint16_t)((motion_tracks[i].right - motion_tracks[i].left + 1) *
                                                   (motion_tracks[i].bottom - motion_tracks[i].top + 1));
                if (motion_tracks[j].hold_timer > motion_tracks[i].hold_timer) {
                    motion_tracks[i].hold_timer = motion_tracks[j].hold_timer;
                }
                motion_tracks[j].active = 0;
            }
        }
    }

    uint8_t valid=0;
    for(unsigned i=0;i<4;i++) {
        output[i]=0;
        if(motion_tracks[i].active) {
            valid|=1u<<i;
            output[i]=pack_motion_box(motion_tracks[i].left,motion_tracks[i].right,motion_tracks[i].top,motion_tracks[i].bottom);
        }
    }
    return valid;
}
