package com.kaltura.hls.m2ts
{	
	import flash.utils.ByteArray;
	
	/**
	 * Incrementally parse an M2TS stream and issue callbacks as we extract packets.
	 */
	public class M2TSParser
	{
		public static var _totalh264:ByteArray = new ByteArray();

		private var _buffer:ByteArray;
		private var _callbacks:IM2TSCallbacks;
		private var _packets:Array;
		private var _types:Array;
		private var _pesPackets:Array;
		
		public function M2TSParser(callbacks:IM2TSCallbacks = null)
		{
			_types = new Array;
			clear();
			setCallbacks(callbacks);
		}
		
		public function flush():void
		{
			var tmp:ByteArray = new ByteArray();
			
			for each (var p:PacketStream in _packets)
				p.appendBytes(tmp, 0, 0, true, uint(-1), true, handlePacketComplete, onPacketProgress);
			
			for (var idx:* in _pesPackets)
				parsePESPacketStreamComplete(_pesPackets[idx], uint(idx), true);
			
			clear();
		}
		
		public function clear():void
		{
			_buffer = new ByteArray();
			_packets = new Array();
			_pesPackets = new Array();
		}
		
		public function reset():void
		{
			clear();
			_types = [];
		}
		
		public function setCallbacks(callbacks:IM2TSCallbacks):void
		{
			if(!callbacks)
				callbacks = new NullM2TSHandler();
			
			_callbacks = callbacks;
		}
		
		private function scanForNALUStart(cursor:int, bytes:ByteArray):int
		{
			var curPos:int;
			var length:int = bytes.length - 3;
			
			for(curPos = cursor; curPos < length; curPos++)
			{
				if((    bytes[curPos    ] == 0x00)
					&& (bytes[curPos + 1] == 0x00)
					&& (bytes[curPos + 2] == 0x01))
					return curPos;
			}
			
			return -1;
		}
		
		private function scanForNALUEnd(cursor:int, bytes:ByteArray):int
		{
			var curPos:int;
			var length:int = bytes.length - 3;
			
			for(curPos = cursor; curPos < length; curPos++)
			{
				if((     bytes[curPos    ] == 0x00)
					&&  (bytes[curPos + 1] == 0x00)
					&& ((bytes[curPos + 2] == 0x01) || (bytes[curPos + 2] == 0x00)))
					return curPos;
			}
			
			return -1;
		}
		
		public function appendBytes(bytes:ByteArray):void
		{
			_buffer.position = _buffer.length;
			_buffer.writeBytes(bytes);
			
			var cursor:uint = 0;
			var len:uint = _buffer.length;
			
			while(true)
			{
				var scanCount:int = 0;
				while(cursor + 187 < len)
				{
					if(0x47 == _buffer[cursor])  // search for TS sync byte
						break;

					cursor++;
					scanCount++;
				}

				if(scanCount > 0)
					trace("WARNING: appendBytes - skipped " + scanCount + " bytes to sync point.");
				
				if(cursor + 188 > len)
					break;
				
				parseTSPacket(cursor);
				
				cursor += 188;
			}
			
			// Snarf remainder into beginning of buffer.
			var remainder:uint = _buffer.length - cursor;
			_buffer.position = 0;
			_buffer.writeBytes(_buffer, cursor, remainder);
			_buffer.length = remainder;

/*			var x:uint;
			for(x = 0; x < remainder; x++)
				_buffer[x] = _buffer[cursor + x];
			_buffer.length = remainder;*/
		}
		
		private function parseTSPacket(cursor:uint):void
		{
			var payloadStart:Boolean;
			var packetID:uint;
			var hasAdaptationField:Boolean;
			var hasPayload:Boolean;
			var continuityCounter:uint;
			var headerLength:uint = 4;
			var payloadLength:uint;
			var discontinuity:Boolean = false;

			// Decode header bytes.
			payloadStart 		=  (_buffer[cursor + 1] & 0x40) != 0;
			packetID 			= ((_buffer[cursor + 1] & 0x1f) << 8) + _buffer[cursor + 2];
			continuityCounter 	=   _buffer[cursor + 3] & 0x0f;
			hasPayload 			=  (_buffer[cursor + 3] & 0x10) != 0;
			hasAdaptationField 	=  (_buffer[cursor + 3] & 0x20) != 0;
			
			// Set up rest of parsing.
			if(hasAdaptationField)
			{
				var adaptationFieldLength:uint = _buffer[cursor + 4];
				if(adaptationFieldLength > 183)
					return; // invalid

				headerLength += adaptationFieldLength + 1;
				
				discontinuity = (_buffer[cursor + 5] & 0x80) != 0;
			}
			
			payloadLength = 188 - headerLength;
			
			if(!hasPayload)
				return;

			switch(packetID)
			{
				case 0x1fff:
					break; // padding
				default:
					trace("parseTSPacket - Saw packet ID " + packetID + " at "  + cursor + " start " + payloadStart + " headerLen=" + headerLength + " payloadLen=" + payloadLength + " continuityCounter=" + continuityCounter + " discontinuity=" + discontinuity);
					parseTSPayload(packetID, payloadStart, continuityCounter, discontinuity, cursor + headerLength, payloadLength);
					break;
			}
		}
		
		private function parseTSPayload(packetID:uint, payloadStart:Boolean, continuityCounter:uint, discontinuity:Boolean, cursor:uint, length:uint):void
		{
			var stream:PacketStream = _packets[packetID];
			if(!stream)
			{
				stream = new PacketStream(packetID);
				_packets[packetID] = stream;
			}
			
			stream.appendBytes(_buffer, cursor, length, payloadStart, continuityCounter, discontinuity, handlePacketComplete, onPacketProgress);
		}
		
		private function parseProgramMapTable(bytes:ByteArray, cursor:uint):Boolean
		{
			var sectionLength:uint;
			var sectionLimit:uint;
			var programInfoLength:uint;
			var type:uint;
			var pid:uint;
			var esInfoLength:uint;
			var seenPIDsByClass:Array;
			var mediaClass:int;

			// Set up types.
			_types = [];
			seenPIDsByClass = [];
			seenPIDsByClass[MediaClass.VIDEO] = Infinity;
			seenPIDsByClass[MediaClass.AUDIO] = Infinity;
			
			// Process section length and limit.
			cursor++;
			
			sectionLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
			cursor += 2;

			if(sectionLength + cursor > bytes.length)
				return false;
			
			// Skip a few things we don't care about: program number, RSV, version, CNI, section, last_section, pcr_cid
			sectionLimit = cursor + sectionLength;			
			cursor += 7;
			
			// And get the program info length.
			programInfoLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
			cursor += 2;
			
			// If not enough data to proceed, bail.
			if(programInfoLength + cursor > bytes.length)
				return false;

			cursor += programInfoLength;
						
			const CRC_SIZE:int = 4;
			while(cursor < sectionLimit - CRC_SIZE)
			{
				type = bytes[cursor++];
				pid = ((bytes[cursor] & 0x1f) << 8) + bytes[cursor + 1];
				cursor += 2;
				
				mediaClass = MediaClass.calculate(type);
				
				// For video & audio, select the lowest PID for each kind.
				if(mediaClass == MediaClass.OTHER
				 || pid < seenPIDsByClass[mediaClass]) 
				{
					// Clear a higher PID if present.
					if(mediaClass != MediaClass.OTHER
					 && seenPIDsByClass[mediaClass] < Infinity)
						_types[seenPIDsByClass[mediaClass]] = -1;
					
					_types[pid] = type;
					seenPIDsByClass[mediaClass] = pid;
				}
				
				// Skip the esInfo data.
				esInfoLength = ((bytes[cursor] & 0x0f) << 8) + bytes[cursor + 1];
				cursor += 2;
				cursor += esInfoLength;
			}
			
			return true;
		}
		
		private function parseMP3Packet(pts:Number, dts:Number, cursor:uint, bytes:ByteArray):uint
		{
			_callbacks.onMP3Packet(pts, dts, bytes, cursor, bytes.length - cursor);
			return bytes.length;
		}
		
		private function parseAACPacket(pts:Number, dts:Number, cursor:uint, bytes:ByteArray, flushing:Boolean):uint
		{
			if(bytes.length - cursor < 7)
			{
				trace("Only got " + bytes.length + " against " + cursor + " so aborting AAC parse");
				return cursor;
			}
			
			//trace("pts = " + pts + " dts = " + dts + " A");

			_callbacks.onAACPacket(pts, bytes, cursor, bytes.length - cursor);

			return bytes.length;
		}
		
		private function parseAVCPacket(pts:Number, dts:Number, cursor:uint, bytes:ByteArray, flushing:Boolean):uint
		{
			var originalStart:int = int(cursor);
			var start:int = int(cursor);
			var end:int;
			var naluLength:uint;

			start = scanForNALUStart(start, bytes);
			while(start >= 0)
			{
				end = scanForNALUEnd(start + 3, bytes);
				if(end >= 0)
					naluLength = end - start;
				else if(flushing)
					naluLength = bytes.length - start;
				else
				{
					//trace("parseAVCPAcket - Exiting due to no NALU before end");
					break;
				}
				
				_callbacks.onAVCNALU(pts, dts, bytes, uint(start), naluLength);
				
				cursor = start + naluLength;
				start = scanForNALUStart(start + naluLength, bytes);

				trace("SAW NALU at " + (_totalh264.length + (cursor - originalStart) + 3) + " naluLength=" + (naluLength - 3));
			}
			
			if(flushing)
				_callbacks.onAVCNALUFlush(pts, dts);
			
			// Save consumed bytes into the master buffer.
			_totalh264.writeBytes(bytes, originalStart, cursor - originalStart);

			trace("Total buffer size " + _totalh264.length);

			return cursor;
		}
		
		private function parsePESPacketStreamComplete(pes:PESPacketStream, packetID:uint, flushing:Boolean):void
		{
			var cursor:uint = 0;
			var bytes:ByteArray = pes._buffer;
			var pts:Number = pes._pts;
			var dts:Number = pes._dts;
			
			trace("parsePESPacketStreamComplete - pts=" + pts + ", dst=" + dts + ", type=" + _types[packetID] + ", bufferLength=" + bytes.length);

			switch(_types[packetID])
			{
				case 0x03: // ISO 11172-3 MP3 audio
				case 0x04: // ISO 13818-3 MP3-betterness audio
					cursor = parseMP3Packet(pts, dts, cursor, bytes);
					break;
					
				case 0x0f: // AAC audio in ADTS transport syntax
					cursor = parseAACPacket(pts, dts, cursor, bytes, flushing);
					break;
					
				case 0x1b: // H.264/MPEG-4 AVC
					cursor = parseAVCPacket(pts, dts, cursor, bytes, flushing);
					break;
					
				default:
					//trace("Handling other type");
					_callbacks.onOtherElementaryPacket(packetID, _types[packetID], pts, dts, cursor, bytes);
					cursor = bytes.length;
					break;
			}
			
			trace("Consumed " + cursor + " bytes");
			pes.shiftLeft(cursor);
		}
		
		private function parsePESPacket(packetID:uint, type:uint, bytes:ByteArray):void
		{
			var streamID:uint = bytes[3];
			var packetLength:uint = (bytes[4] << 8) + bytes[5];
			var cursor:uint = 6;
			var pts:Number = -1;
			var dts:Number = -1;
			var pes:PESPacketStream;
			
			switch(streamID)
			{
				case 0xbc: // program stream map
				case 0xbe: // padding stream
				case 0xbf: // private_stream_2
				case 0xf0: // ECM_stream
				case 0xf1: // EMM_stream
				case 0xff: // program_stream_directory
				case 0xf2: // DSMCC stream
				case 0xf8: // H.222.1 type E
					_callbacks.onOtherPacket(packetID, bytes);
					return;
				
				default:
					break;
			}
			
			if(packetLength)
			{
				if(bytes.length < packetLength )
				{
					trace("WARNING: parsePESPacket - not enough bytes, expecting " + (packetLength) + ", but have " + bytes.length);
					return; // not enough bytes in packet
				}
			}
			
			if(bytes.length < 9)
			{
				trace("WARNING: parsePESPacket - too short");
				return;
			}
			
			var dataAlignment:Boolean = (bytes[cursor] & 0x04) != 0;
			cursor++;
			
			var ptsDts:uint = (bytes[cursor] & 0xc0) >> 6;
			cursor++;
			
			var pesHeaderDataLength:uint = bytes[cursor];
			cursor++;
			
			if(ptsDts & 0x02)
			{
				// has PTS at least
				if(cursor + 5 > bytes.length)
					return;
				
				pts  = bytes[cursor] & 0x0e;
				pts *= 128;
				pts += bytes[cursor + 1];
				pts *= 256;
				pts += bytes[cursor + 2] & 0xfe;
				pts *= 128;
				pts += bytes[cursor + 3];
				pts *= 256;
				pts += bytes[cursor + 4] & 0xfe;
				pts /= 2;
				
				if(ptsDts & 0x01)
				{
					if(cursor + 10 > bytes.length)
						return;
					
					dts  = bytes[cursor + 5] & 0x0e;
					dts *= 128;
					dts += bytes[cursor + 6];
					dts *= 256;
					dts += bytes[cursor + 7] & 0xfe;
					dts *= 128;
					dts += bytes[cursor + 8];
					dts *= 256;
					dts += bytes[cursor + 9] & 0xfe;
					dts /= 2;
				}
				else
					dts = pts;
			}
			cursor += pesHeaderDataLength;
			if(cursor > bytes.length)
			{
				trace("WARNING: parsePESPacket - out 1");
				return;
			}
			
			if(_types[packetID] == undefined)
			{
				trace("WARNING: parsePESPacket - out 2");
				return;
			}
			
			if(_pesPackets[packetID] == undefined)
			{
				if(dts < 0.0)
				{
					trace("WARNING: parsePESPacket - out 3");
					return;
				}
				
				pes = new PESPacketStream(pts, dts);
				_pesPackets[packetID] = pes;
			}
			else
			{
				pes = _pesPackets[packetID];
			}
			
			trace("Appending " + bytes.length + ", cursor=" + cursor);
			pes._buffer.position = pes._buffer.length; // - 1 > 0 ? pes._buffer.length - 1 : 0;
			pes._buffer.writeBytes(bytes, cursor);

			trace("TRIGGERING COMPLETE PES STREAM");
			pes._pts = pts;
			pes._dts = dts;
			parsePESPacketStreamComplete(pes, packetID, false);

		}
		
		private function handlePacketComplete(packetID:uint, bytes:ByteArray):void
		{
			if(bytes.length < 3)
			{
				trace("WARNING: handlePacketComplete - too short packet");
				return;
			}

			if( (bytes[0] == 0x00)
			 && (bytes[1] == 0x00)
			 && (bytes[2] == 0x01))
			{
				// an elementary stream
				parsePESPacket(packetID, _types[packetID], bytes);
				return;
			}

			var cursor:uint = bytes[0] + 1;
			var remaining:uint;
			
			if(cursor > bytes.length)
				return;
			
			remaining = bytes.length - cursor;
			
			if( (remaining < 23)
			 || (bytes[cursor] != 0x02)
			 || ((bytes[cursor + 1] & 0xfc)) != 0xb0)
			{
				trace("handlePacketComplete - Firing other callback for " + remaining + " bytes.");
				_callbacks.onOtherPacket(packetID, bytes);
			}
		}
		
		private function onPacketProgress(packetID:uint, bytes:ByteArray):Boolean
		{
			//trace("packet progress " + packetID + " len=" + bytes.length);

			// Too short?
			if(bytes.length < 3)
				return false;
			
			// Skip PES.
			if(bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x01)
				return false;

			var cursor:uint = bytes[0] + 1;
			var remaining:uint;

			// Invalid, past end of data.			
			if(cursor > bytes.length)
				return false;
			
			remaining = bytes.length - cursor;
			if( (remaining >= 23)
			 && (0x02 == bytes[cursor]) // program map section
			 && (0xb0 == (bytes[cursor + 1] & 0xfc)))
				return parseProgramMapTable(bytes, cursor);
			
			return false;
		}
	}
}

import com.kaltura.hls.m2ts.IM2TSCallbacks;
import flash.utils.ByteArray;

/**
 * Helper for MPEG2 packet stream parsing. Filters bytes into packets and issues
 * callbacks.
 */
internal class PacketStream
{
	public function PacketStream(packetID:uint)
	{
		_buffer = new ByteArray();
		_packetID = packetID;
		_lastContinuity = -1;
	}
	
	public function appendBytes(bytes:ByteArray, offset:uint, length:uint, payloadStart:Boolean, continuityCounter:uint, discontinuity:Boolean, onComplete:Function, onProgress:Function):void
	{
		if(_lastContinuity == continuityCounter)
		{
			// Ignore duplicate packets.
			if( (!payloadStart)
			 && (!discontinuity))
			{
				trace("WARNING: duplicate packet!");
				return; // duplicate
			}
		}
		
		if(payloadStart)
		{
			if(_buffer.length > 0)
				trace("WARNING: Flushed due to payloadStart flag, didn't predict length properly!");
			onPacketComplete(onComplete);
		}
		else
		{
			if(_lastContinuity < 0)
			{
				trace("WARNING: Saw discontinuous packet!");
				return;
			}
			
			if( (((_lastContinuity + 1) & 0x0f) != continuityCounter) && !discontinuity)
			{
				// Corrupt packet - skip it.
				trace("WARNING: Saw corrupt packet!");
				_buffer.length = 0;
				_lastContinuity = -1;
				return;
			}

			if(_buffer.length == 0 && length > 0)
				trace("WARNING: Got new bytes without PUSI set!");
		}
		
		_buffer.position = _buffer.length;

		if(length > 0)
			_buffer.writeBytes(bytes, offset, length);

		_lastContinuity = continuityCounter;
		
		if( (length > 0)
		 && (_buffer.length > 1)
		 && (onProgress(_packetID, _buffer)))
		{
			trace("RESETTING BUFFER FOR " + _packetID +", tossing " + _buffer.length + " bytes");
			_buffer.length = 0;
			_lastContinuity = -1;
		}

		// Check to see if we can fire a complete PES packet...
		if(_buffer.length > 5)
		{
			// Extract length...
			var packetLength:uint = ((_buffer[4] << 8) + _buffer[5]);

			// Check against observed payload.
			if(packetLength > 0)
			{
				trace("looking for length of "  + (packetLength+6) + " and had length of " + _buffer.length);
				if(_buffer.length >= packetLength + 6)
				{
					if(_buffer.length > packetLength + 6)
						trace("WARNING: Got buffer strictly longer than expected. This is OK when on first packet of stream.");
					onPacketComplete(onComplete);
				}				
			}
		}
	}
	
	private function onPacketComplete(onComplete:Function):void
	{
		if(_buffer.length > 1)
		{
			//trace("onPacketComplete -- FLUSH " + _packetID + " length=" + _buffer.length);
			onComplete(_packetID, _buffer);
		}
		
		_buffer.length = 0;
	}
	
	private var _buffer:ByteArray;
	private var _bufferLength:uint;
	private var _packetID:uint;
	private var _lastContinuity:int;
	private var _isPayloadNotPsi:Boolean;
}

/**
 * Helper for processing PES streams.
 */
internal class PESPacketStream
{
	public function PESPacketStream(pts:Number, dts:Number)
	{
		_buffer = new ByteArray();
		_shiftBuffer = new ByteArray();
		_pts = pts;
		_dts = dts;
	}
	
	public function shiftLeft(num:int):void
	{
		var newLength:int = _buffer.length - num;
		var tmpBytes:ByteArray;
		
		_shiftBuffer.length = 0;
		_shiftBuffer.position = 0;
		_shiftBuffer.writeBytes(_buffer, num, newLength);
		
		tmpBytes = _buffer;
		_buffer = _shiftBuffer;
		_shiftBuffer = tmpBytes;
		
	}
	
	public var _buffer:ByteArray;
	public var _pts:Number;
	public var _dts:Number;
	
	private var _shiftBuffer:ByteArray;
}

/**
 * Easier to have a dummy callback handler than check for presence. 
 */
internal class NullM2TSHandler implements com.kaltura.hls.m2ts.IM2TSCallbacks
{
	public function NullM2TSHandler() {}
	
	public function onMP3Packet(pts:Number, dts:Number, bytes:ByteArray, cursor:uint, length:uint):void {}
	public function onAACPacket(pts:Number, bytes:ByteArray, cursor:uint, length:uint):void {}
	public function onAVCNALU(pts:Number, dts:Number, bytes:ByteArray, cursor:uint, length:uint):void {}
	public function onAVCNALUFlush(pts:Number, dts:Number):void {}
	public function onOtherElementaryPacket(packetID:uint, type:uint, pts:Number, dts:Number, cursor:uint, bytes:ByteArray):void {}
	public function onOtherPacket(packetID:uint, bytes:ByteArray):void {}
}
