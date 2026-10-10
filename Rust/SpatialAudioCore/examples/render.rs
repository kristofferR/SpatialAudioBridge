use spatial_audio_core::{decode::Core,render::Layout};
use std::{env,fs::File,io::{BufWriter,Read,Write}};
/// Renders an elementary stream to interleaved Float32 speaker feeds and reports each channel's
/// peak and how many samples exceed full scale. Pass /dev/null as the output to measure only.
fn main()->Result<(),Box<dyn std::error::Error>> {
    let args:Vec<_>=env::args().collect();
    if !(4..=5).contains(&args.len()) {return Err("usage: render <truehd|dtsx> <elementary-stream> <output.f32le> [7.1.4|9.1.6]".into());}
    let codec=match args[1].as_str() {"truehd"=>1,"dtsx"=>2,_=>return Err("unknown codec".into())};
    let layout=match args.get(4).map(String::as_str) {None|Some("9.1.6")=>Layout::NineOneSix,Some("7.1.4")=>Layout::SevenOneFour,_=>return Err("unknown layout".into())};
    let channels=layout as usize;
    let mut core=Core::new(codec,layout)?;
    let mut input=File::open(&args[2])?;let mut output=BufWriter::new(File::create(&args[3])?);
    let mut buffer=[0u8;4096];let mut frames=0u64;let mut rate=0;
    let (mut peak,mut over,mut energy)=(vec![0f32;channels],vec![0u64;channels],vec![0f64;channels]);
    let started=std::time::Instant::now();
    loop {
        let n=input.read(&mut buffer)?;
        core.push(&buffer[..n],n==0,&mut |pcm| {
            frames+=pcm.frames as u64;rate=pcm.rate;
            for (i,x) in pcm.data.iter().enumerate() {
                let c=i%channels;
                peak[c]=peak[c].max(x.abs());energy[c]+=(*x as f64).powi(2);
                if x.abs()>1.0 {over[c]+=1;}
            }
            let bytes:Vec<u8>=pcm.data.iter().flat_map(|x|x.to_le_bytes()).collect();
            output.write_all(&bytes).map_err(|e|e.to_string())
        })?;
        if n==0 {break;}
    }
    let db=|x:f64|20.0*x.max(1e-12).log10();
    println!("frames={frames} rate={rate} duration={:.6}s elapsed={:.3}s",frames as f64/rate as f64,started.elapsed().as_secs_f64());
    for c in 0..channels {
        println!("channel {c:2}: peak {:+6.1} dBFS, rms {:+6.1} dBFS, {} samples above full scale",
                 db(peak[c] as f64),db((energy[c]/frames.max(1) as f64).sqrt()),over[c]);
    }
    Ok(())
}
