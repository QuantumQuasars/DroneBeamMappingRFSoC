`timescale 1ns / 1ps

/*

The overall goal is for this verilog ("us") to take a "window" of 2^16 signed int16 samples coming in at 4 GSPS,
add it to the next window of 2^16 samples, and do this for a while (milliseconds to seconds), 
somewhere between 1000 and 2^16 times.

Then we dump the 2^16 signed int32 accumulation results into dual-port RAM so that the ARM
processor can read it out slowly, but before the next accumulation period ends and we need to dump again.

The number of samples in a window is not actually fixed at 2^16,
but is a function of the MEM_SIZE_BYTES parameter.
Eventually this will be somewhat adjustable from python using the "samples_in_window" input.
The number of windows to add together before a dump is given by the "num_accumulations" input, which can be set from python.

In more detail:

The ADC and DAC are streaming data at 4 GSPS over the AXIS (streaming) bus.
These samples come in "chunks" or "transfers" of 16 (signed) int16 samples at a time in parallel:

+-------+-------+-----------------------+-------+-------+
| int16 | int16 | .... 16 of these .... | int16 | int16 | (DWIDTH=256 bits wide)
+-------+-------+-----------------------+-------+-------+

These 256-bit wide chunks come in at 4 GHz / 16 = 250 MHz, a manageable rate.
(In the RF Data Converter settings block, Samples per AXI4-Stream Cycle = 8, 
  but in the heir_dac_accumulate block, before we reach this Verilog block,
  there's an AXI4-Stream Data Width Converter that widens and slows by 2x).

The original MTS code writes some number of these chunks into dual-port BRAM and then stops,
after which they can be read out by the ARM processor as a numpy array of signed int16 samples.
Original capture code: https://github.com/Xilinx/RFSoC-MTS/blob/main/boards/ip/rtl/ADCRAMcapture.v

Incoming data, arranged into one long "window":
+------------------------+----------------------------------+-------------------------+
| 0th group of 16 int16s | ... around 2^16 int16s total ... | last group of 16 int16s |
+------------------------+----------------------------------+-------------------------+

From here out, I'll call this long group of samples a "window".
This is because it'll eventually be FFTed as one sequence.
The signal that we are listening to should repeat exactly once per "window",
and we want to coherently average a bunch of them together (between 2**10 and 2**20).

Again, a typical length for this window is something like 2^16=65536 int16 samples,
though the actual number is set by samples_in_window, which needs to be a multiple of 16.
At the default rates, these windows each last 16.384 us and repeat at at 61 kHz.

Stepping back for a second... because we can't transfer all samples to the ARM at 4 GSPS:
1. The original MTS solution is to trigger on something and only transfer one window's worth of samples, 
      pausing for a long time after it finishes, skipping lots of sample before the next trigger.
2. The signal that this code is written for repeats with a period of exactly the length of one window,
      and the signal repeats right away, over and over again forever.
      This means we can "average away the noise" by summing all of 0th samples, 1st samples, etc.

The AccumulateAndDump verilog code here arranges for this. We add samples together into (signed) int32s,
meaning we can accumulate up to 2**16 of these windows before the int32s in a given sample slot might overflow.

The internal accumulator that we instantiate in verilog below, 
which gets dumped to dual-port BRAM of the same size:
+------------------------+----------------------------------+-------------------------+
| 0th group of 16 int32s | ... around 2^16 int32s total ... | last group of 16 int32s |
+------------------------+----------------------------------+-------------------------+

We will arrange this into many rows, which Verilog infers into a large RAM called accumulator:
+----------------------------------+
|     0th group of 16 int32s       |  row: 0
+----------------------------------+
| ... around 2^16 int32s total ... |  each row is 16*32 = 512 bits
+----------------------------------+
|    last group of 16 int32s       |  row: NUMBER_OF_ROWS-1
+----------------------------------+


This leads to a maximum accumulation time of around 1.07 seconds for 2**16 accumulations of 2**16 samples at 4 GSPS.
The actual number of accumulations is set by the "num_accumulations" input.
This should be big enough that the result can be completely read into python before the next sum needs to be dumped,
but short enough to avoid the overflow errors mentioned above.

We don't want any gaps between accumulations, so as soon as one is done,
the very next incoming sample *needs* to dealt with to start the next round.
For this, we use a double-buffer strategy,
where we instantiate a large accumulator array here in verilog.
As the chunks of samples from the *last* accumulation window arrive, 
we still add these incoming samples to the accumulator,
but rather than write them back to the accumulator,
we turn on an external write-enable signal to write them to an external dual-port BRAM,
whose other port can be read by the ARM. This is the dump.

We also keep track of whether there were arithmetic overflows or underflows,
thus letting the processor know that the data is invalid for that accumulation period.
This should only ever happen if the accumulation period 
was chosen to be too long (longer than about a second in the example above).
For small-amplitude signals that are mostly noise, one might choose to make the buffer longer,
hoping that statistically there will not be overflow or underflow.
I don't recommend this, but I wanted to record overflows so the ARM never unknowingly looks at invalid data.

There are also flags and state-machine logic to:
* tell the ARM that the external dual-port RAM is full and ready to be read (dump_ready)
* let the ARM tell this Verilog that it's reading the dual-port RAM (reading_dump) and it shouldn't be updated
* make sure the ARM is done reading by the time we have to do the next dump, otherwise drop it and record the drop (dropped_count)

There are two ways for the ARM to know it didn't read a dump fast enough:
* the sequence_number will have a gap as compared to the previous sequence number
* the dropped_count will not be zero.

The normal order of operations for an ARM python program interfacing with this module is to:
* set trig_cap high once to start the accumulate-and-dump state machine
* loop as many times as you want:
  - wait for rising edge on dump_ready
  - set reading_dump to high (verilog in this file will quickly set dump_ready to false)
  - copy the accumulated data from hardware BRAM into the ARM's (python's) RAM as fast as possible
  - read the 3 int32 status registers on this dump: sequence_number, overflow_count, dropped_count
  - set reading_dump low to tell this verilog that the ARM is done and that
        verilog can write to the dual-port BRAM and status registers again
* set trig_cap low to stop the hardware accumulate-and-dump

The most common thing that I imagine can go wrong is for python to take too long to read the dual-port BRAM.
This shows up when the verilog code below is ready to dump to BRAM, but reading_dump is still high.
This should skip the BRAM dump processes for the entire accumulation period,
increment dropped_count, but still increment sequence_number and zero the accumulator.

Another thing that can go wrong is that python fails to begin reading before the next dump needs to happen.
This should also be treated as a drop as above. NO new data should be written to the BRAM.
The python will know it messed up because the next sequence number will be more than one above the previous one it read.
I thought about writing the new data, but we'd need to turn off dump_ready, which may have just been read into python as high.
The BRAM and status registers should only ever be set to a valid accumulated window, even if that means it's old data waiting to be read.

TODO: I don't think we handle these two errors exactly as described.
For example, if python is still reading the BRAM during the first few chunks of the new dump,
but then stops reading before the last few chunks, I think the BRAM will get partially updated.
At least in this case dropped_count gets incremented to let python know there was a problem.

User errors we don't deal with:
If python starts reading the dual-port BRAM before dump_ready goes high,
or python doesn't tell the verilog that it's reading the BRAM by setting reading_dump high,
this verilog code has no sympathy for you and doesn't make any promises about the validity
of the BRAM or the status registers.

*/

module AccumulateAndDump #(parameter DWIDTH = 256, parameter MEM_SIZE_BYTES = 65536) (
  (* X_INTERFACE_PARAMETER = "MASTER_TYPE BRAM_CTRL, READ_WRITE_MODE READ, MEM_SIZE 32768, MEM_WIDTH 256" *)

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_A DIN" *)
  output reg [DWIDTH*2-1:0] bram_wdata, // Data In Bus (optional)

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_A WE" *)
  output reg [DWIDTH*2/8-1:0] bram_we, // Byte Enables (optional)

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_A EN" *)
  output reg bram_en, // Chip Enable Signal (optional)

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_A DOUT" *)
  input wire [DWIDTH*2-1:0] bram_rdata, // Data Out Bus (optional)

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_A ADDR" *)
  output reg [31:0] bram_addr, // Address Signal (required)

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_A CLK" *)
  output wire bram_clk, // Clock Signal (required)

  (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_A RST" *)
  output wire bram_rst, // Reset Signal (required)

  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF CAP_AXIS, ASSOCIATED_RESET axis_aresetn" *)
  input wire axis_clk,  // the streaming clock controls everything

  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axis_aresetn RST" *)
  // incoming stream
  input  wire              axis_aresetn,    // active low reset for everything
  input  wire [DWIDTH-1:0] CAP_AXIS_tdata,  // incomming "capture" data, of 256 bits of 16 int16s.
  output wire              CAP_AXIS_tready, // AXIS control signal
  input  wire              CAP_AXIS_tvalid, // AXIS control signal

  input  wire              trig_cap,        // trigger the capture just after when this goes high
  
  // Dump
  input wire [31:0]        samples_in_window,       // Needs to be a multiple 16 or it'll get rounded down. Needs to fit in the memory. By default, it should exactly fill the memory. TODO: stop ignoring this, which we do now.
  input wire [31:0]        num_accumulations,       // The number of accumulations before a dump. If it's too high, we are likely to overflow or underflow the in32 sums.
  input wire               reading_dump,            // The ARM sets this high right before it starts reading the BRAM and low when it's done. We won't write to the BRAM if this is high, but we might drop a dump.
  output reg               dump_ready,              // We set this high when the BRAM is ready for the ARM to read. We set it low when ARM changes reading_dump from low to high when it starts reading.
  output reg [31:0]        sequence_number,         // a running count of dumps or attempted dumps. Starts at 0 when a trigger comes in and only ever increments.
  output reg [31:0]        overflow_count,          // How many adds overflowed in the previous accumulation period (basically used to determine if the contents of BRAM valid or not)
  output reg [31:0]        dropped_count            // How many windows were dropped due to ARM still reading when a dump needed to happen. Maybe the ARM should figure this out from a skipped sequence_number, but right now it needs this to know about partially-written dumps.
   );
   
   /*
   The original code dumped samples to external BRAM as they came in in groups of 16 int16 samples.
   This new version accumulates them into a large int32 chunk of INTERNAL memory that's created right here in Verilog.
   Once the final set of samples comes in, it dumps those to the external BRAM and resets the internal accumulator.
   */

  localparam ADDR_INC = DWIDTH*2/8;   // amount that the address increases each cycle. The BRAM is addressed by bytes, not rows of 512 bits. It holds int32s, not int16s like in the original code, thus *2.
  localparam CAP_SIZE = MEM_SIZE_BYTES;  // CAP refers to the incoming stream that we "capture". Not sure why the original code didn't just use MEM_SIZE_BYTES. This determines when we are at the last address.
  localparam TRIGCAP_HI = 15;  // Length of shift register to delay the trig_cap trigger input. Not sure why the original MTS code did this, but so do we.
  (* ASYNC_REG="TRUE" *) reg [TRIGCAP_HI:0] trig_cap_p = 0;  // shift register 
  
  localparam SAMPLES_PER_TRANSFER = DWIDTH/16;  // Each chunk is made of int16s, and with DWIDTH=256, this is 16
  localparam NUMBER_OF_ROWS = MEM_SIZE_BYTES/(DWIDTH*2/8);  // Memory "depth" of our 512-bit wide internal accumulator (16 int32s at a time)
  localparam ROW_ADDR_WIDTH = $clog2(NUMBER_OF_ROWS);  // this many bits to address rows of our wide internal accumulator
  reg [ROW_ADDR_WIDTH-1:0] accumulator_addr;  // Address of internal accumulator memory. This is row number, where each row is 16 samples * int32 = 512 bit (not byte address like we need for external RAM)
  reg [DWIDTH*2-1:0] accumulator [NUMBER_OF_ROWS-1:0];  // The huge internal accumulator memory. Maybe this will need to move to external BRAM or URAM, but there is latency
  reg [31:0] accumulations_count;  // a medium-speed counter that counts the number of accumulations we've done to know when to do a dump. Counts from 0 to maximum_accumulations = num_accumulations-1.
  
  
  // Fast    counter is accumulator_addr    -- counts how many 16-sample (256 bits of int16 -> 512 bits of int32) parallel accumulations we've done
  // Medium  counter is accumulations_count -- counts how many times each slot in the accumulator has been added to (number of windows we've added so far) before a dump
  // Slow    counter is sequence_number     -- gets incremented every time we dump the accumulator
  
  // Make local versions of the GPIO inputs so: 1. they don't change while running and 2.to help make timing. 
  reg [31:0]        maximum_row_address;   // For now, this ends up always being the constant (NUMBER_OF_ROWS-1), which fills the entire memory. TODO: use the samples_in_window GPIO input
  reg [31:0]        maximum_accumulations; // Becomes num_accumulations-1
  reg [31:0]        overflow_count_so_far;  // Externally, we always present overflow_count, which is from the last long accumulation period and changes only when we dump. This keeps keeps track until we dump.
  reg [$clog2(SAMPLES_PER_TRANSFER+1)-1:0] overflow_and_underflow_this_cycle;  // running sum of overflows and underflows this clock cycle (originally 31:0) (+1 because they might all overflow)
  
  // temporary variables inside of loop
  reg  signed [DWIDTH*2-1:0] temp_sum;  // important to declare it signed? Does "signed" apply once to all 512 bits or does it apply to each of the 16 int32s this holds?
  //reg  [SAMPLES_PER_TRANSFER:0]  overflow;
  //reg  [SAMPLES_PER_TRANSFER:0]  underflow;
  
  reg last_time_reading_dump;  // too look for transitions from low to high when the ARM tells us it's reading the external BRAM.
  
  assign bram_clk = axis_clk;       // connect stream clock to BRAM clock
  assign bram_rst = ~axis_aresetn;  // connect stream reset to BRAM clock
  assign CAP_AXIS_tready = 1'b1;    // tell the stream we are always ready to get data.  I guess we are always ready.
  assign trig_cap_posedge = ~trig_cap_p[TRIGCAP_HI] & trig_cap_p[TRIGCAP_HI-1];  // if the oldest is low but the next oldest is high, it's a rising pulse trigger
 
  //sync trig_cap to cap_clk and add bit for rising pulse detect. This was copied from original MTS code.
  always @(posedge axis_clk) begin
    if (~axis_aresetn) begin  // if we are resetting,
      trig_cap_p <= 0;  // set the entire trigger shift register to 0s.
    end else begin
      trig_cap_p <= {trig_cap_p[TRIGCAP_HI-1:0], trig_cap};  // shift the new trig_cap input into the lowest bit of the register
    end
  end
  
  integer i;  // for when we loop over the 16 int16 samples in each incoming 256-bit chunk
  
  //Accumulate and Dump counters
  always @(posedge axis_clk) begin
    
    if (!last_time_reading_dump && reading_dump) begin
      // The ARM raised the reading_dump input from low to high, which should only happen if this Verilog set dump_ready to high.
      dump_ready <= 0;  // Reset dump_ready for next time. (This accumulator-result dump is no longer ready if checked again by the ARM).
    end
    last_time_reading_dump <= reading_dump; // remember this to detect a rising edge
    
    // TODO: maybe synchronize things to the rising edge of the 1pps. Maybe this happens outside of this block by mucking with the trig_cap input
    if (~axis_aresetn || trig_cap_posedge) begin  // If we are resetting or starting a trigger
      dump_ready             <= 0;
      overflow_count         <= 0;
      overflow_count_so_far  <= 0;
      dropped_count          <= 0;
      accumulator_addr       <= 0;  // Fast counter
      accumulations_count    <= 0;  // Medium counter
      sequence_number        <= 0;  // Slow counter, exposed to software through GPIO. Except here, this only ever increments
      maximum_row_address    <= NUMBER_OF_ROWS-1;  // TODO: calculate this from samples_in_window: samples_in_window/SAMPLES_PER_TRANSFER rounded down. Maybe samples_in_window[31:4]-1
      maximum_accumulations  <= num_accumulations-1;
      
      // tell the external BRAM that we're not writing or reading:
      bram_addr <= 0;
      bram_we   <= 0;
      bram_en   <= 0;
      // zero out the accumulator. This is not necessary and may add significantly to syhthesis unless resets of the entire memory can happen in parallel
      //for (int i = 0; i < NUMBER_OF_ROWS; i = i + 1) begin
      //  accumulator[i] <= 0;
      //end
    end else begin  // else we are not resetting
      if (trig_cap && CAP_AXIS_tvalid) begin  // We we are running and have a valid sample. Is tvalid high for more than one cycle? I hope not.
        // If this is the first group of samples to be accumulated within this dump, just write them to the accumulator rather than adding:
        if (accumulations_count==0) begin
          // We are just getting started, so don't add anything, just sign extend this first group of samples into the accumulator
          for (i=0; i<SAMPLES_PER_TRANSFER; i=i+1) begin : sign_extend_for_loop  // loop over the 16 int16 samples
             accumulator[accumulator_addr][32*i +: 32] <= $signed( CAP_AXIS_tdata[16*i +: 16] );   // +: means up 16 bits
          end
          //accumulator[accumulator_addr] <= 1; // OLD DEBUG CODE: put in a 1 just to see something at all.
        end else begin
          // this isn't the first group going into the accumulator, so we need to add these incoming 16 samples to what's already there
          overflow_and_underflow_this_cycle = 0;  // becomes a combinatorial "ones count" of overflows and underflows from the ~16 parallel samples
          for (i=0; i<SAMPLES_PER_TRANSFER; i=i+1) begin : signed_add_loop  // loop over the 16 int16 samples
             // Note: Blocking assignments (=) used only here for temporary variables.
             temp_sum[32*i +: 32] = $signed( CAP_AXIS_tdata[16*i +: 16] ) + $signed(accumulator[accumulator_addr][32*i +: 32]);
             // Old way of breaking up overflow into pieces.
             //overflow[i]  = (~CAP_AXIS_tdata[16*i+15]) & (~accumulator[accumulator_addr][32*i+31]) & ( temp_sum[32*i+31]);  // two positives make a negative
             //underflow[i] = ( CAP_AXIS_tdata[16*i+15]) & ( accumulator[accumulator_addr][32*i+31]) & (~temp_sum[32*i+31]);  // two negatives make a positive
             //if (overflow[i] || underflow[i]) begin
             //   overflow_and_underflow_this_cycle = overflow_and_underflow_this_cycle + 1;
             //end
             // New way, instead do it all in one shot for efficiency.
             if (((~CAP_AXIS_tdata[16*i+15]) & (~accumulator[accumulator_addr][32*i+31]) & ( temp_sum[32*i+31])) |         // overflow:  two positives make a negative
                 (( CAP_AXIS_tdata[16*i+15]) & ( accumulator[accumulator_addr][32*i+31]) & (~temp_sum[32*i+31]))) begin    // underflow: two negatives make a positive
                overflow_and_underflow_this_cycle = overflow_and_underflow_this_cycle + 1;
             end
          end
          accumulator[accumulator_addr] <= temp_sum;
          overflow_count_so_far <= overflow_count_so_far + overflow_and_underflow_this_cycle;
          //accumulator[accumulator_addr] <= accumulator[accumulator_addr] + 1;  // DEBUG: Just add 1 to test.
          //accumulator[accumulator_addr][31:0] <= accumulator[accumulator_addr][31:0] + 1;  // DEBUG: make this an int32 add rather than a 512 bit add for timing.
          // If this is the last window, dump the result to the external BRAM. No need to zero the accumulator -- it'll just get overwritten next time.
          if (accumulations_count==maximum_accumulations && reading_dump) begin  // but first check if we're not allowed to dump because the ARM is still reading the current dump
            dropped_count <= dropped_count+1; // TODO: This counts dropped rows, not dropped long accumulation periods.
          end
          if (accumulations_count==maximum_accumulations && !reading_dump) begin
            // TODO: What should we do if reading_dump goes low for chunks within this maximum_accumulations set?
            //overflow_count <= CAP_AXIS_tdata[15:0];  // DEBUG: just to see one sample. Careful of signed business.
            //overflow_count <= CAP_AXIS_tdata[31:0];  // DEBUG: just to see TWO samples. Careful of signed business.
            //dropped_count  <= accumulator[accumulator_addr][31:0]; // DEBUG: just to see something at all
            //dropped_count <= temp_sum[31:0];  // DEBUG: just to see the result of an accumulation
            bram_wdata <= temp_sum;
            bram_addr  <= bram_addr + ADDR_INC;  // go to the next address
            bram_we    <= {DWIDTH*2/8{1'b1}};  // turn on write enable for each byte.
            bram_en    <= 1'b1;  // Enable the BRAM
          end else begin  // not writing
            bram_addr <= 0;  // hang out at address 0 until we are ready to write
            bram_we   <= {DWIDTH*2/8{1'b0}};  // turn off write enable for each byte.
            bram_en   <= 1'b0;  // turn off the BRAM enable.
          end
          
        end  // end the check for whether this is the first or non-first row to be accumulated.
        
        // Increment all counters, but check for rollover first.
        // If we are the last row of the accumulator, go back to the first row and increase accumulations_count
        if (accumulator_addr==maximum_row_address) begin  // check fast counter to be at its max
            accumulator_addr <= 0; // reset the fast counter
            if (accumulations_count==maximum_accumulations) begin  // check medium counter to be at its max
              // if we're here, it means we just wrote the last accumulation result to the external BRAM
              accumulations_count <= 0; // reset the medium counter
              sequence_number <= sequence_number+1;  // Increment the slow counter, which shouldn't roll over for a long time (and is python's problem anyway)
              overflow_count <= overflow_count_so_far;  // Present the number of overflows (basically a valid flag)
              overflow_count_so_far <= 0;  // reset the running total of overflows
              if (!reading_dump) begin // if python is not still actively reading, which should have led to drops, tell it that it can start now
                dump_ready <= 1;
              end
              // else we probably need to increment the dropped_count but we did that above. Maybe move that here?
            end else begin
              accumulations_count <= accumulations_count+1; // Increment the medium counter
            end
        end else begin
            accumulator_addr <= accumulator_addr+1; // Increment the fast counter
        end
      
      end else begin  // Not capturing or not a valid sample
        bram_we   <= {DWIDTH*2/8{1'b0}};  // turn off write enable for each byte.
        bram_en   <= 1'b0;  // turn off the BRAM enable.
      end
      
    end
  end

endmodule
