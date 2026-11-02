// Combinational RAW10 pedestal subtraction. No added data/control latency.
module raw10_blc(input wire [39:0] data_in,input wire enable,
    input wire [7:0] offset,output wire [39:0] data_out);
    genvar i;
    generate for(i=0;i<4;i=i+1) begin: lane
        wire [9:0] p=data_in[i*10+:10];
        assign data_out[i*10+:10]=!enable ? p :
            (p>{2'b0,offset} ? p-{2'b0,offset} : 10'd0);
    end endgenerate
endmodule
