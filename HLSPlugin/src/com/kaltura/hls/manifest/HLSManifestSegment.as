package com.kaltura.hls.manifest
{
	public class HLSManifestSegment
	{
		public var id:int;   // Based on the mediaSequence number
		public var uri:String;
		public var duration:Number;
		public var title:String;
		public var startTime:Number;
		public var continuityEra:int;
		
		// Byte Range support. -1 means no byte range.
		public var byteRangeStart:int = -1;
		public var byteRangeEnd:int = -1;
	}
}