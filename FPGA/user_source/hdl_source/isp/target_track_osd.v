// Decimal tracking annotation. 2-cycle RGB/sync pipeline, same as legacy OSD.
// Commit snapshots the numbers in vertical blanking. Keep DE low for the next
// 544 clocks: eight slots, each with 36 BCD and 32 glyph-decoder cycles.
// Small per-slot distributed glyph memories replace eight live font decoders.
// They need no reset: ready publishes only a complete set. No ERAM is consumed.
// A new commit restarts preparation; reset cancels it. No division hardware.
// Stage12: y already names the next active row during horizontal blanking.
// Nine DE-low clocks prepare all eight row descriptors (one launch + eight
// slots). The production 720p path provides 370 clocks. Records stay stable
// until commit; count/error/result_valid remain live per-pixel qualifiers.
module target_track_osd(
    input wire clk,reset_n,commit,
    input wire [23:0] rgb, input wire de,hs,vs,
    input wire [10:0] x, input wire [9:0] y,
    input wire [511:0] records, input wire [3:0] count,
    input wire [15:0] total, input wire [7:0] error,
    input wire overflow,result_valid,
    output reg [23:0] out_rgb, output reg out_de,out_hs,out_vs
);
    reg busy,ready;
    reg [3:0] step;
    reg [2:0] convert_slot;
    reg [1:0] convert_field;
    reg [10:0] binary_shift;
    reg [15:0] bcd_work;
    reg [10:0] center_x[0:7];
    reg [9:0] center_y[0:7];
    // Records remain stable between commits. Labels use explicitly sized logic.
    wire [10:0] label_x[0:7];
    reg [7:0] saved_id[0:7];
    // Only the current slot's decimal values survive until its glyphs are
    // written. bcd_work retains the last conversion (ID) during glyph output.
    reg [15:0] bcd_x,bcd_y;
    reg [1:0] saved_class[0:7];
    reg preparing_glyphs;
    reg [4:0] glyph_index;
    wire [2:0] glyph_slot=convert_slot;
    wire [1:0] glyph_class=saved_class[convert_slot];
    reg [7:0] glyph_code;
    // Decode the character position directly instead of building/selecting
    // two 128-bit strings. Keep all spaces and leading zeroes unchanged.
    always @* begin
        glyph_code=" ";
        case(glyph_index)
            0:glyph_code="I";
            1:glyph_code="D";
            2,17,24:glyph_code=":";
            3:glyph_code=digit(bcd_work[11:8]);
            4:glyph_code=digit(bcd_work[7:4]);
            5:glyph_code=digit(bcd_work[3:0]);
            7:glyph_code=glyph_class==1?"R":glyph_class==2?"C":"U";
            8:glyph_code=glyph_class==1?"E":glyph_class==2?"I":"N";
            9:glyph_code=glyph_class==1?"C":glyph_class==2?"R":"K";
            10:glyph_code=glyph_class==1?"T":glyph_class==2?"C":"N";
            11:glyph_code=glyph_class==1?" ":glyph_class==2?"L":"O";
            12:glyph_code=glyph_class==1?" ":glyph_class==2?"E":"W";
            13:glyph_code=(glyph_class==1 || glyph_class==2)?" ":"N";
            16:glyph_code="X";
            18:glyph_code=digit(bcd_x[15:12]);
            19:glyph_code=digit(bcd_x[11:8]);
            20:glyph_code=digit(bcd_x[7:4]);
            21:glyph_code=digit(bcd_x[3:0]);
            23:glyph_code="Y";
            25:glyph_code=digit(bcd_y[15:12]);
            26:glyph_code=digit(bcd_y[11:8]);
            27:glyph_code=digit(bcd_y[7:4]);
            28:glyph_code=digit(bcd_y[3:0]);
            default:glyph_code=" ";
        endcase
    end
    wire [14:0] prepared_glyph;
    target_osd_glyph shared_font(.code(glyph_code),.glyph(prepared_glyph));
    function [15:0] add3;
        input [15:0] v; integer n;
        begin
            add3=v;
            for(n=0;n<4;n=n+1) if(v[n*4+:4]>=5) add3[n*4+:4]=v[n*4+:4]+4'd3;
        end
    endfunction
    wire [15:0] bcd_next=(add3(bcd_work)<<1)|{15'b0,binary_shift[10]};
    function [7:0] digit; input [3:0] d; begin digit=8'd48+{4'b0,d}; end endfunction
    function [10:0] cx;
        input [63:0] r; reg [11:0] sum;
        begin sum={1'b0,r[41:31]}+{1'b0,r[30:20]}; cx=sum[11:1]; end
    endfunction
    function [9:0] cy;
        input [63:0] r; reg [10:0] sum;
        begin sum={1'b0,r[19:10]}+{1'b0,r[9:0]}; cy=sum[10:1]; end
    endfunction
    integer j;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            busy<=0; ready<=0; step<=0; preparing_glyphs<=0; glyph_index<=0;
            convert_slot<=0; convert_field<=0; binary_shift<=0; bcd_work<=0;
            bcd_x<=0;bcd_y<=0;
            for(j=0;j<8;j=j+1) begin
                center_x[j]<=0; center_y[j]<=0; saved_id[j]<=0; saved_class[j]<=0;
            end
        end else if(commit) begin
            busy<=1; ready<=0; step<=0; preparing_glyphs<=0; glyph_index<=0;
            convert_slot<=0; convert_field<=0;
            for(j=0;j<8;j=j+1) begin
                center_x[j]<=cx(records[j*64+:64]); center_y[j]<=cy(records[j*64+:64]);
                saved_id[j]<=records[j*64+44+:8];
                saved_class[j]<=records[j*64+42+:2];
            end
        end else if(busy) begin
            if(preparing_glyphs) begin
                if(glyph_index==31) begin
                    preparing_glyphs<=0;glyph_index<=0;
                    if(convert_slot==7) begin busy<=0;ready<=1;end
                    else convert_slot<=convert_slot+1'b1;
                end
                else glyph_index<=glyph_index+1'b1;
            end else if(step==0) begin
                case(convert_field)
                    0: binary_shift<=center_x[convert_slot];
                    1: binary_shift<={1'b0,center_y[convert_slot]};
                    default: binary_shift<={3'b0,saved_id[convert_slot]};
                endcase
                bcd_work<=0;
                step<=1;
            end else begin
                binary_shift<=binary_shift<<1;
                bcd_work<=bcd_next;
                if(step==11) begin
                    case(convert_field)
                        0:bcd_x<=bcd_next;
                        1:bcd_y<=bcd_next;
                        default:; // ID stays in bcd_work throughout glyph output.
                    endcase
                    step<=0;
                    if(convert_field==2) begin
                        convert_field<=0;
                        preparing_glyphs<=1;glyph_index<=0;
                    end else convert_field<=convert_field+1'b1;
                end else step<=step+1'b1;
            end
        end
    end
    // BEGIN STAGE12_LINE_PREP
    // Only row-invariant predicates move here. No scanline pixel buffer,
    // new ERAM, or extra RGB/sync pipeline stage is introduced.
    reg line_busy,line_valid;
    reg [2:0] line_slot;
    reg [9:0] line_y;
    // [8] box Y range, [7] horizontal box edge, [6] horizontal cross,
    // [5] vertical cross, [4] text active, [3] second text line, [2:0] font row.
    reg [8:0] line_flags[0:7];
    wire [19:0] prep_bounds=records[{line_slot,6'b0}+:20];
    wire [9:0] prep_ymin=prep_bounds[19:10],prep_ymax=prep_bounds[9:0];
    wire [9:0] prep_cy=center_y[line_slot];
    wire [9:0] prep_ty=prep_ymin>=10'd24 ? prep_ymin-10'd24:
        prep_ymax<=10'd695 ? prep_ymax+10'd2:10'd696;
    wire [9:0] prep_ly=line_y-prep_ty;
    wire prep_second=prep_ly>=10'd12;
    wire [9:0] prep_gy=prep_second ? prep_ly-10'd12:prep_ly;
    wire [9:0] prep_prev=line_y-10'd1,prep_next=line_y+10'd1;
    wire [9:0] prep_cross_lo=line_y<10'd5 ? 10'd0:line_y-10'd5;
    wire [9:0] prep_cross_hi=line_y>10'd1018 ? 10'd1023:line_y+10'd5;
    wire [8:0] prepared_line={
        line_y>=prep_ymin && line_y<=prep_ymax,
        line_y==prep_ymin || prep_prev==prep_ymin ||
            line_y==prep_ymax || prep_next==prep_ymax,
        line_y==prep_cy,
        prep_cy>=prep_cross_lo && prep_cy<=prep_cross_hi,
        line_y>=prep_ty && prep_ly<10'd22 && prep_gy<10'd10,
        prep_second,prep_gy[3:1]};
    // Publish only after all slots are written. If a caller violates the
    // blanking contract, suppress stale row annotations and retry in blanking.
    wire line_ok=line_valid && line_y==y;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            line_busy<=0;line_valid<=0;line_slot<=0;line_y<=0;
        end else if(commit) begin
            line_busy<=0;line_valid<=0;line_slot<=0;
        end else if(!de) begin
            if(line_y!=y || (!line_busy && !line_valid)) begin
                line_y<=y;line_slot<=0;line_busy<=1;line_valid<=0;
            end else if(line_busy) begin
                if(line_slot==7) begin line_busy<=0;line_valid<=1;end
                else line_slot<=line_slot+1'b1;
            end
        end else if(line_busy) begin
            line_busy<=0;line_valid<=0;
        end
    end
    // No reset on data: line_valid guards unwritten/partially written flags.
    always @(posedge clk)
        if(reset_n && !commit && !de && line_busy && line_y==y)
            line_flags[line_slot]<=prepared_line;
    // END STAGE12_LINE_PREP
    wire [7:0] hit;
    wire [191:0] ink;
    // Shared narrow coordinate neighbours replace 32-bit per-slot differences.
    // The enclosing box range checks exclude wraparound at coordinate limits.
    wire [10:0] x_prev=x-11'd1,x_next=x+11'd1;
    // The +/-5 window belongs to the current pixel and is shared by all slots.
    // Saturation prevents wraparound at the full coordinate limits.
    wire [10:0] cross_xlo=x<11'd5 ? 11'd0:x-11'd5;
    wire [10:0] cross_xhi=x>11'd2042 ? 11'd2047:x+11'd5;
    genvar k;
    generate for(k=0;k<8;k=k+1) begin: slot
        wire [63:0] r=records[k*64+:64];
        wire [1:0] cls=r[43:42];
        wire [10:0] xmin=r[41:31],xmax=r[30:20];
        assign label_x[k]=xmin>11'd1152 ? 11'd1152:xmin;
        wire [10:0] tx=label_x[k];
        wire [10:0] lx=x-tx;
        wire [8:0] row_state=line_flags[k];
        wire second=row_state[3];
        (* ram_style="dram" *) reg [14:0] glyphs[0:31];
        always @(posedge clk)
            if(reset_n && !commit && busy && preparing_glyphs && glyph_slot==k)
                glyphs[glyph_index[4:0]]<=prepared_glyph;
        wire [14:0] glyph=glyphs[{second,lx[6:3]}];
        reg [2:0] row_bits;
        always @* case(row_state[2:0])
            0:row_bits=glyph[14:12];1:row_bits=glyph[11:9];2:row_bits=glyph[8:6];
            3:row_bits=glyph[5:3];4:row_bits=glyph[2:0];default:row_bits=0;
        endcase
        wire dot=lx[2:1]==0?row_bits[2]:lx[2:1]==1?row_bits[1]:lx[2:1]==2?row_bits[0]:1'b0;
        wire border=x>=xmin && x<=xmax && row_state[8] &&
            (x==xmin || x_prev==xmin || x==xmax || x_next==xmax ||
             row_state[7]);
        wire cross_hit=(center_x[k]>=cross_xlo && center_x[k]<=cross_xhi && row_state[6]) ||
                       (row_state[5] && x==center_x[k]);
        wire text_hit=x>=tx && lx<128 && row_state[4] && dot;
        assign hit[k]=ready && line_ok && result_valid && error==0 && k<count && (border || cross_hit || text_hit);
        assign ink[k*24+:24]=cls==1?24'h00aa46:cls==2?24'h0096e6:24'hffd200;
    end endgenerate
    function [7:0] hexchar;
        input [3:0] v; begin hexchar=v<10?8'd48+v:8'd65+v-10; end
    endfunction
    wire [127:0] status_word={"N:",hexchar(total[15:12]),hexchar(total[11:8]),hexchar(total[7:4]),hexchar(total[3:0]),
        " E:",hexchar(error[7:4]),hexchar(error[3:0])," O:",hexchar({3'b0,overflow})," "};
    wire [10:0] sx=x-11'd8; wire [9:0] sy=y-10'd8;
    wire [6:0] status_offset={~sx[6:3],3'b000};
    wire [7:0] status_code=status_word[status_offset+:8];
    wire status_dot;
    target_osd_font sf(.code(status_code),.row(sy[3:1]),.col(sx[2:1]),.pixel(status_dot));
    reg [23:0] paint; reg paint_hit; integer n;
    always @* begin
        paint=0; paint_hit=0;
        for(n=7;n>=0;n=n-1) if(hit[n]) begin paint_hit=1; paint=ink[n*24+:24]; end
        if(result_valid && x>=8 && sx<128 && y>=8 && sy<10 && status_dot) begin
            paint_hit=1; paint=error==0?24'hfff200:24'hff4040;
        end
    end
    reg [23:0] rgb_d,paint_d;
    reg de_d,hs_d,vs_d,hit_d;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            rgb_d<=0; paint_d<=0; de_d<=0; hs_d<=0; vs_d<=0; hit_d<=0;
            out_rgb<=0; out_de<=0; out_hs<=0; out_vs<=0;
        end else begin
            rgb_d<=rgb; paint_d<=paint; de_d<=de; hs_d<=hs; vs_d<=vs; hit_d<=paint_hit;
            out_rgb<=de_d && hit_d?paint_d:rgb_d; out_de<=de_d; out_hs<=hs_d; out_vs<=vs_d;
        end
    end
endmodule
