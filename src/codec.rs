use tokio_util::codec::{Decoder, Encoder};
use tokio_util::bytes::{BytesMut, BufMut, Buf};
use std::io;

#[derive(Debug, Clone)]
pub enum Package {
    Message(BytesMut, BytesMut),
    Subscribe(BytesMut),
    Unsubscribe(BytesMut),
    Ping(BytesMut),
    Pong(BytesMut)
}

pub struct Codec;

impl Decoder for Codec {
    type Item = Package;
    type Error = io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        // the first two bytes are the following package length
        let size = {
            if src.len() < 2 {
                return Ok(None);
            } else {
                src.get_u16() as usize
            }
        };

        if size > 0 && src.len() >= size {
            let mut buf = src.split_to(size);

            let package_type = buf.first().map(|&v| v);
            buf.advance(1);

            match package_type {
                Some(value) => {
                    match value {
                        // message and subscriptions operate with channel ID
                        0 | 1 | 2 => {
                            let id_size = match buf.first() {
                                None => 0,
                                Some(x) => *x
                            } as usize;
                            buf.advance(1);

                            if buf.len() < id_size { return Ok(None); }
                            let id = buf.split_to(id_size);

                            match value {
                                0 => Ok(Some(Package::Message(id, buf))),
                                1 => Ok(Some(Package::Subscribe(id))),
                                2 => Ok(Some(Package::Unsubscribe(id))),
                                _ => Ok(None)
                            }
                        }
                        // ping and pong need only content
                        3 => Ok(Some(Package::Ping(buf))),
                        4 => Ok(Some(Package::Pong(buf))),
                        _ => Ok(None)
                    }
                }
                None => Ok(None)
            }
        } else {
            Ok(None)
        }
    }
}

impl Encoder<Package> for Codec {
    type Error = io::Error;

    fn encode(&mut self, pkg: Package, dst: &mut BytesMut) -> Result<(), Self::Error> {
        let mut bytes = BytesMut::new();

        match pkg {
            Package::Message(id, message) => {
                bytes.reserve(2 + id.len() + message.len());
                bytes.put_u8(0);
                bytes.put_u8(id.len() as u8);
                bytes.put_slice(id.as_ref());
                bytes.put_slice(message.as_ref());
            }
            Package::Subscribe(id) => {
                bytes.reserve(2 + id.len());
                bytes.put_u8(1);
                bytes.put_u8(id.len() as u8);
                bytes.put_slice(id.as_ref());
            }
            Package::Unsubscribe(id) => {
                bytes.reserve(2 + id.len());
                bytes.put_u8(2);
                bytes.put_u8(id.len() as u8);
                bytes.put_slice(id.as_ref());
            }
            Package::Ping(content) => {
                bytes.reserve(1 + content.len());
                bytes.put_u8(3);
                bytes.put_slice(content.as_ref());
            }
            Package::Pong(content) => {
                bytes.reserve(1 + content.len());
                bytes.put_u8(4);
                bytes.put_slice(content.as_ref());
            }
        }

        dst.reserve(bytes.len() + 2);
        dst.put_u16(bytes.len() as u16);
        dst.put(bytes);

        Ok(())
    }
}
