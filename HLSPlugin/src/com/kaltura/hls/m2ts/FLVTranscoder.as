package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

    /**
     * Responsible for emitting FLV data. Also handles AAC conversion
     * config and buffering.
     */
    public class FLVTranscoder
    {
        public const MIN_FILE_HEADER_BYTE_COUNT:int = 9;

        public var callback:Function;
        
        private var lastTagSize:uint = 0;

        private var _aacConfig:ByteArray;
        private var _aacRemainder:ByteArray;
        private var _aacTimestamp:Number = 0;

        public function clear(clearAACConfig:Boolean = false):void
        {
            if(clearAACConfig)
                _aacConfig = null;
            _aacRemainder = null;
            _aacTimestamp = 0;
        }

        private function sendFLVTag(flvts:uint, type:uint, codec:int, mode:int, bytes:ByteArray, offset:uint, length:uint):void
        {
            var tag:ByteArray = new ByteArray();
            tag.position = 0;
            var msgLength:uint = length + ((codec >= 0) ? 1 : 0) + ((mode >= 0) ? 1 : 0);
            var cursor:uint = 0;
            
            if(msgLength > 0xffffff)
                return; // too big for the length field
            
            tag.length = FLVTags.HEADER_LENGTH + msgLength; 
            tag[cursor++] = type;
            tag[cursor++] = (msgLength >> 16) & 0xff;
            tag[cursor++] = (msgLength >>  8) & 0xff;
            tag[cursor++] = (msgLength      ) & 0xff;
            tag[cursor++] = (flvts >> 16) & 0xff;
            tag[cursor++] = (flvts >>  8) & 0xff;
            tag[cursor++] = (flvts      ) & 0xff;
            tag[cursor++] = (flvts >> 24) & 0xff;
            tag[cursor++] = 0x00; // stream ID
            tag[cursor++] = 0x00;
            tag[cursor++] = 0x00;
            
            if(codec >= 0)
                tag[cursor++] = codec;
            if(mode >= 0)
                tag[cursor++] = mode;
                
            tag.position = cursor;
            tag.writeBytes(bytes, offset, length);
            
            cursor += length;
            msgLength += 11; // account for message header in back pointer

            tag.writeUnsignedInt(lastTagSize);

            lastTagSize = tag.length;

            // Dispatch tag.
            if(callback != null)
                callback(flvts, tag);

        }

        public function convertFLVTimestamp(pts:Number):Number 
        {
            return pts / 90.0;
        }

        private static var flvGenerationBuffer:ByteArray = new ByteArray();

        /**
         * Convert and amit AVC NALU data.
         */
        public function convert(unit:NALU):void
        {
            // Emit an AVCC.
            var avcc:ByteArray = NALUProcessor.extractAVCC(unit);
            if(avcc)
                sendFLVTag(convertFLVTimestamp(unit.pts), FLVTags.TYPE_VIDEO, FLVTags.VIDEO_CODEC_AVC_KEYFRAME, FLVTags.AVC_MODE_AVCC, avcc, 0, avcc.length);            

            // Accumulate NALUs into buffer.
            flvGenerationBuffer.length = 3;
            flvGenerationBuffer[0] = (tsu >> 16) & 0xff;
            flvGenerationBuffer[1] = (tsu >>  8) & 0xff;
            flvGenerationBuffer[2] = (tsu      ) & 0xff;
            flvGenerationBuffer.position = 3;

            // Check keyframe status.
            var keyFrame:Boolean = false;
            var totalAppended:int = 0;
            NALUProcessor.walkNALUs(unit.buffer, 0, function(bytes:ByteArray, cursor:uint, length:uint):void
            {
                // Check for a NALU that is keyframe type.
                var naluType:uint = bytes[cursor] & 0x1f;
                //trace(naluType + " length=" + length);
                switch(naluType)
                {
                    case 0x09: // "access unit delimiter"
                        switch((bytes[cursor + 1] >> 5) & 0x07) // access unit type
                        {
                            case 0:
                            case 3:
                            case 5:
                                keyFrame = true;
                                break;
                            default:
                                keyFrame = false;
                                break;
                        }
                        break;

                    default:
                        // Infer keyframe state.
                        if(naluType == 5)
                            keyFrame = true;
                        else if(naluType == 1)
                            keyFrame = false;                        
                }

                // Append.
                flvGenerationBuffer.writeUnsignedInt(length);
                flvGenerationBuffer.writeBytes(bytes, cursor, length);
                totalAppended += length;
            }, true );

            var flvts:uint = convertFLVTimestamp(unit.pts);
            var tsu:uint = convertFLVTimestamp(unit.pts - unit.dts);

            var codec:uint;
            if(keyFrame)
                codec = FLVTags.VIDEO_CODEC_AVC_KEYFRAME;
            else
                codec = FLVTags.VIDEO_CODEC_AVC_PREDICTIVEFRAME;

            //trace("ts=" + flvts + " tsu=" + tsu + " keyframe = " + keyFrame);
            
            sendFLVTag(flvts, FLVTags.TYPE_VIDEO, codec, FLVTags.AVC_MODE_PICTURE, flvGenerationBuffer, 0, flvGenerationBuffer.length);
        }

        private function compareBytesHelper(b1:ByteArray, b2:ByteArray):Boolean
        {
            var curPos:uint;
            
            if(b1.length != b2.length)
                return false;
            
            for(curPos = 0; curPos < b1.length; curPos++)
            {
                if(b1[curPos] != b2[curPos])
                    return false;
            }
            
            return true;
        }

        private function sendAACConfigFLVTag(flvts:uint, profile:uint, sampleRateIndex:uint, channelConfig:uint):void
        {
            var isNewConfig:Boolean = true;
            var audioSpecificConfig:ByteArray = new ByteArray();
            var audioObjectType:uint;
            
            audioSpecificConfig.length = 2;
            
            switch(profile)
            {
                case 0x00:
                    audioObjectType = 0x01;
                    break;
                case 0x01:
                    audioObjectType = 0x02;
                    break;
                case 0x02:
                    audioObjectType = 0x03;
                    break;
                default:
                    return;
            }
            
            audioSpecificConfig[0] = ((audioObjectType << 3) & 0xf8) + ((sampleRateIndex >> 1) & 0x07);
            audioSpecificConfig[1] = ((sampleRateIndex << 7) & 0x80) + ((channelConfig << 3) & 0x78);
            
            if(_aacConfig && compareBytesHelper(_aacConfig, audioSpecificConfig))
                isNewConfig = false;
            
            if(!isNewConfig)
                return;

            _aacConfig = audioSpecificConfig;
            sendFLVTag(flvts, FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_AAC, FLVTags.AAC_MODE_CONFIG, _aacConfig, 0, _aacConfig.length);
        }

        /**
         * Convert and amit AAC data.
         */
        public function convertAAC(pes:PESPacket):void
        {            
            var timeAccumulation:Number = 0.0;
            var limit:uint;
            var stream:ByteArray;
            var hadRemainder:Boolean = false;
            var cursor:int = 0;
            var length:int = pes.buffer.length;
            var bytes:ByteArray = pes.buffer;
            var timestamp:Number = pes.pts;
            
            if(_aacRemainder)
            {
                stream = _aacRemainder;
                stream.writeBytes(bytes, cursor, length);
                cursor = 0;
                length = stream.length;
                _aacRemainder = null;
                hadRemainder = true;
                timeAccumulation = _aacTimestamp - timestamp;
            }
            else
                stream = bytes;
            
            limit = cursor + length;
            
            // an AAC PES packet can contain multiple ADTS frames
            while(cursor < limit)
            {
                var remaining:uint = limit - cursor;
                var sampleRateIndex:uint;
                var sampleRate:Number = undefined;
                var profile:uint;
                var channelConfig:uint;
                var frameLength:uint;
                
                if(remaining < FLVTags.ADTS_FRAME_HEADER_LENGTH)
                    break;
                
                // search for syncword
                if(stream[cursor] != 0xff || (stream[cursor + 1] & 0xf0) != 0xf0)
                {
                    cursor++;
                    continue;
                }
                
                frameLength  = (stream[cursor + 3] & 0x03) << 11;
                frameLength += (stream[cursor + 4]) << 3;
                frameLength += (stream[cursor + 5] >> 5) & 0x07;
                
                // Check for an invalid ADTS header; if so look for next syncword.
                if(frameLength < FLVTags.ADTS_FRAME_HEADER_LENGTH)
                {
                    cursor++;
                    continue;
                }
                
                // Skip it till next PES packet.
                if(frameLength > remaining)
                    break;
                
                profile = (stream[cursor + 2] >> 6) & 0x03;
                
                sampleRateIndex = (stream[cursor + 2] >> 2) & 0x0f;
                switch(sampleRateIndex)
                {
                    case 0x00:
                        sampleRate = 96000.0;
                        break;
                    case 0x01:
                        sampleRate = 88200.0;
                        break;
                    case 0x02:
                        sampleRate = 64000.0;
                        break;
                    case 0x03:
                        sampleRate = 48000.0;
                        break;
                    case 0x04:
                        sampleRate = 44100.0;
                        break;
                    case 0x05:
                        sampleRate = 32000.0;
                        break;
                    case 0x06:
                        sampleRate = 24000.0;
                        break;
                    case 0x07:
                        sampleRate = 22050.0;
                        break;
                    case 0x08:
                        sampleRate = 16000.0;
                        break;
                    case 0x09:
                        sampleRate = 12000.0;
                        break;
                    case 0x0a:
                        sampleRate = 11025.0;
                        break;
                    case 0x0b:
                        sampleRate = 8000.0;
                        break;
                    case 0x0c:
                        sampleRate = 7350.0;
                        break;
                }
                
                channelConfig = ((stream[cursor + 2] & 0x01) << 2) + ((stream[cursor + 3] >> 6) & 0x03);
                
                if(sampleRate)
                {
                    var flvts:uint = convertFLVTimestamp(timestamp + timeAccumulation);
                    
                    sendAACConfigFLVTag(flvts, profile, sampleRateIndex, channelConfig);
                    //trace("Sending AAC");
                    sendFLVTag(flvts, FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_AAC, FLVTags.AAC_MODE_FRAME, stream, cursor + FLVTags.ADTS_FRAME_HEADER_LENGTH, frameLength - FLVTags.ADTS_FRAME_HEADER_LENGTH);
                    
                    timeAccumulation += (1024.0 / sampleRate) * 90000.0; // account for the duration of this frame
                    
                    if(hadRemainder)
                    {
                        timeAccumulation = 0.0;
                        hadRemainder = false;
                    }
                }
                
                cursor += frameLength;
            }
            
            if(cursor < limit)
            {
                //trace("AAC timestamp was " + _aacTimestamp);
                _aacRemainder = new ByteArray();
                _aacRemainder.writeBytes(stream, cursor, limit - cursor);
                _aacTimestamp = timestamp + timeAccumulation;
                //trace("AAC timestamp now " + _aacTimestamp);
            }            
        }

        /**
         * Convert and amit MP3 data.
         */
        public function convertMP3(pes:PESPacket):void
        {
            sendFLVTag(convertFLVTimestamp(pes.pts), FLVTags.TYPE_AUDIO, FLVTags.AUDIO_CODEC_MP3, -1, pes.buffer, 0, pes.buffer.length);
        }

        private function generateScriptData(values:Array):ByteArray
        {
            var bytes:ByteArray = new ByteArray();
            bytes.objectEncoding = ObjectEncoding.AMF0;
            
            for each (var object:Object in values)
                bytes.writeObject(object);
            
            return bytes;
        }
        
        private function sendScriptDataFLVTag(flvts:uint, values:Array):void
        {
            var bytes:ByteArray = generateScriptData(values);
            sendFLVTag(flvts, FLVTags.TYPE_SCRIPTDATA, -1, -1, bytes, 0, bytes.length);
        }

        /**
         * Fire off a subtitle caption.
         */
        public function createAndSendCaptionMessage( timeStamp:Number, captionBuffer:String, lang:String="", textid:Number=99):void
        {
            //var captionObject:Array = ["onCaptionInfo", { type:"WebVTT", data:captionBuffer }];
            //sendScriptDataFLVTag( timeStamp * 1000, captionObject);

            // We need to strip the timestamp off of the text data
            captionBuffer = captionBuffer.slice(captionBuffer.indexOf('\n') + 1);

            var subtitleObject:Array = ["onTextData", { text:captionBuffer, language:lang, trackid:textid }];
            sendScriptDataFLVTag( timeStamp * 1000, subtitleObject);
        }


    }
}