use spatial_audio_core::{decode::Core,render::Layout};
use std::{env,fs::File,io::{Read,Write}};
fn main()->Result<(),Box<dyn std::error::Error>> {
    let args:Vec<_>=env::args().collect();
    if args.len()!=4 {return Err("usage: render <truehd|dtsx> <elementary-stream> <output.f32le>".into());}
    let codec=match args[1].as_str() {"truehd"=>1,"dtsx"=>2,_=>return Err("unknown codec".into())};
    let mut core=Core::new(codec,Layout::NineOneSix)?;
    let mut input=File::open(&args[2])?;let mut output=File::create(&args[3])?;
    let mut buffer=[0u8;4096];let mut frames=0u64;let mut rate=0;let mut peak=0f32;let mut energy=[0f64;16];
    let started=std::time::Instant::now();
    loop {
        let n=input.read(&mut buffer)?;
        core.push(&buffer[..n],n==0,&mut |pcm| {
            frames+=pcm.frames as u64;rate=pcm.rate;
            let mut bytes=Vec::with_capacity(pcm.data.len()*4);
            for (i,x) in pcm.data.iter().enumerate() {peak=peak.max(x.abs());energy[i%16]+=(*x as f64).powi(2);bytes.extend_from_slice(&x.to_le_bytes());}
            output.write_all(&bytes).map_err(|e|e.to_string())
        })?;
        if n==0 {break;}
    }
    println!("frames={frames} rate={rate} duration={:.6}s elapsed={:.3}s peak={peak:.6} energy={energy:?}",frames as f64/rate as f64,started.elapsed().as_secs_f64());
    Ok(())
}
