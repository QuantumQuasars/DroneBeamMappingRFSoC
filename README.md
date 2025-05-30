# DroneBeamMappingRFSoC
A drone with a wide-band RFSoC-based transmitter and an RFSoC-based receiver to map the antenna pattern of a radio telescope

## Abstract

We designed and tested a drone with a wide-band transmitter (down to 30 MHz up to to 1.8 GHz) to measure the complex antenna pattern of radio telescopes. We basically split a VNA in half and flew one half on a drone. Radio telescopes at sub GHz frequencies are often not mechanically steerable. They are composed of arrays of dipoles, troughs, or dishes "pointing up". This makes it challenging to know the antenna pattern of each feed when ground and mechanical conditions cannot perfectly be simulated. The far sidelobes are especially challenging to measure, but must be known accurately to measure highly-redshifted hydrogen. Often such telescopes (e.g. CHIME) are used as an interferometer, with a fixed number of channels (e.g. 1024) across their bandwidth (e.g. 400-800 MHz) leading to a fixed FFT repeating time window (e.g. 2.56 µs). Using a Xilinx RFSoC 4x2 board on a drone, we generate a chirp, sampled at 4 GSPS, which spans exactly this bandwidth and repeats at exactly this FFT time window. This allows us to use the existing correlation infrastructure to measure both the magnitude and phase of the antenna response in each spectral bin and in every direction as the drone flies a spiral hemisphere pattern. In the development phase, we measured the beam pattern of a dual-polarized 1-meter parabolic dish. This required us to implement our own 2-input RFSoC receiver in Verilog and python, with flexibility to mimic the bandwidth, number of spectral channels, and repeating time window of many sub 2 GHz radio telescopes that are deployed or planned.

## Overview of FPGA Verilog and Python

Both the transmitter and receiver use the same FPGA image from the same PYNQ-based microSD card image running on RFSoC 4x2 boards. One board can be used for both tranmsit and receive in the lab without the hastle of GPSDO synchronization.

The starting point was RFSoC-MTS <https://github.com/Xilinx/RFSoC-MTS>, the RFSOC-PYNQ Multi-Tile Synchronization Overlay running on the RFSoC4x2. Yes, it synchronizes the tiles, but it also is a simple project where you can 
* write samples to 2 FPGA RAMs (one for each DAC) as if they were 2 int16 numpy arrays, then
* trigger repeated transmits, squirting the samples out of the 2 DACs at 4 GSPS with no gaps, while
* capturing samples from up to 3 ADCs into 2 FPGA RAMs that are acceessed as3 int16 arrays

I made the following changes:
* We don't need to output or capture the entire array. Instead, you can write a `nSamples` in python which will cause the output to repeat after fewer samples. It must remain a multiple of 16 because the DACs are fed in parallel in groups of 16 samples. This one change is all that is needed for the transmitter, and it can be implimented entire by editing the block diagram in Vivado.
* For the receiver, I don't do any channelization or cross correlation in Verilog. Instead, I implimented a simple [AccumulateAndDump.v](AccumulateAndDump.v) Verilog block. This is an int32 array at least `nSamples` long that gets filled up to the number of samples specified (again a multiple of 16, often lastnig a few µs), after which the next `nSamples` get added to the first group. The process repeats `nAccumulate` times (often lasting 1-100 ms). Then the whole array gets dumped to a python-visible memory location to be read out while the next sample starts the following accumulation cycle, all without gaps. There is a dump counter, overflow flags, and other flags to let python know if it was too slow and missed a dump.

The python also started with the RFSoC-MTS example notebook [rfsocMTS.ipynb](https://github.com/Xilinx/RFSoC-MTS/blob/main/boards/RFSoC4x2/notebooks/rfsocMTS.ipynb) with additions for my verilog modifications above, along with generation of the custom chirp --- specifically a [Zadoff-Chu (ZC) sequence](https://en.wikipedia.org/wiki/Zadoff%E2%80%93Chu_sequence) --- and FFT processing of the accumulated dump.

When used to take data on a drone, the series of accumulated dumps are stored with timestamps for later combination with the logs from the PX4 flight control software.

## Drone flight path planning


# Notes

### Example Radio Telescopes

* CHIME 400–800 MHz  red-shifted hydrogen, pulsars, fast radio bursts.
* CHORD 300-1500 MHz 
* HERA 50–200 MHz
* HIRAX 400–800 MHz
* MWA 70–300 MHz 256 array of 16-element dual-polarisation
* LOFAR 10–240 MHz array of dipole antennas at 1.25 to 30m
* PAPER 100–200 MHz Thirty-two crossed-dipole

