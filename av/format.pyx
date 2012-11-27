from libc.stdlib cimport malloc, free

cimport libav as lib

from .utils cimport err_check, avdict_to_dict, avrational_to_faction
from .utils import Error, LibError

cimport av.codec


cdef class ContextProxy(object):

    def __init__(self, bint is_input):
        self.is_input = is_input
    
    def __dealloc__(self):
        if self.ptr != NULL:
            if self.is_input:
                lib.avformat_close_input(&self.ptr)


cdef class Context(object):
    
    def __init__(self, name, mode='r'):
        
        if mode == 'r':
            self.is_input = True
            self.is_output = False
        elif mode == 'w':
            self.is_input = False
            self.is_output = True
            raise NotImplementedError('no output yet')
        else:
            raise ValueError('mode must be "r" or "w"')
        
        self.name = name
        self.mode = mode
        self.proxy = ContextProxy(self.is_input)
        
        if self.is_input:
            err_check(lib.avformat_open_input(&self.proxy.ptr, name, NULL, NULL))
            err_check(lib.avformat_find_stream_info(self.proxy.ptr, NULL))
        
        self.streams = tuple(stream_factory(self, i) for i in range(self.proxy.ptr.nb_streams))
        self.metadata = avdict_to_dict(self.proxy.ptr.metadata)
    
    def dump(self):
        lib.av_dump_format(self.proxy.ptr, 0, self.name, self.mode == 'w')
    
    def demux(self, streams=None):
        
        cdef bint *include_stream = <bint*>malloc(self.proxy.ptr.nb_streams * sizeof(bint))
        if include_stream == NULL:
            raise MemoryError()
        
        cdef int i
        cdef av.codec.Packet packet
        
        try:
            
            for i in range(self.proxy.ptr.nb_streams):
                include_stream[i] = False
            for stream in streams or self.streams:
                include_stream[stream.index] = True
        
            packet = av.codec.Packet()
            while True:
            
                try:
                    err_check(lib.av_read_frame(self.proxy.ptr, &packet.struct))
                except LibError:
                    break
                    
                if include_stream[packet.struct.stream_index]:
                    packet.stream = self.streams[packet.struct.stream_index]
                    yield packet
            
                # Need to free it anyways.
                packet = av.codec.Packet()
        
        finally:
            free(include_stream)
            


cdef Stream stream_factory(Context ctx, int index):
    
    cdef lib.AVStream *ptr = ctx.proxy.ptr.streams[index]
    
    if ptr.codec.codec_type == lib.AVMEDIA_TYPE_VIDEO:
        return VideoStream(ctx, index, 'video')
    elif ptr.codec.codec_type == lib.AVMEDIA_TYPE_AUDIO:
        return AudioStream(ctx, index, 'audio')
    elif ptr.codec.codec_type == lib.AVMEDIA_TYPE_DATA:
        return DataStream(ctx, index, 'data')
    elif ptr.codec.codec_type == lib.AVMEDIA_TYPE_SUBTITLE:
        return SubtitleStream(ctx, index, 'subtitle')
    elif ptr.codec.codec_type == lib.AVMEDIA_TYPE_ATTACHMENT:
        return AttachmentStream(ctx, index, 'attachment')
    elif ptr.codec.codec_type == lib.AVMEDIA_TYPE_NB:
        return NBStream(ctx, index, 'nb')
    else:
        return Stream(ctx, index)


cdef class Stream(object):
    
    def __init__(self, Context ctx, int index, bytes type=b'unknown'):
        
        if index < 0 or index > ctx.proxy.ptr.nb_streams:
            raise ValueError('stream index out of range')
        
        self.ctx_proxy = ctx.proxy
        self.ptr = self.ctx_proxy.ptr.streams[index]
        self.type = type

        self.codec = av.codec.Codec(self)
        self.metadata = avdict_to_dict(self.ptr.metadata)
    
    def __repr__(self):
        return '<%s.%s #%d %s/%s at 0x%x>' % (
            self.__class__.__module__,
            self.__class__.__name__,
            self.index,
            self.type,
            self.codec.name,
            id(self),
        )
    
    property index:
        def __get__(self): return self.ptr.index
    property id:
        def __get__(self): return self.ptr.id
    property time_base:
        def __get__(self): return avrational_to_faction(&self.ptr.time_base)
    property base_frame_rate:
        def __get__(self): return avrational_to_faction(&self.ptr.r_frame_rate)
    property avg_frame_rate:
        def __get__(self): return avrational_to_faction(&self.ptr.avg_frame_rate)
    property start_time:
        def __get__(self): return self.ptr.start_time
    property duration:
        def __get__(self): return self.ptr.duration
    
    cpdef decode(self, av.codec.Packet packet):
        return None
    


cdef class VideoStream(Stream):
    pass

cdef class AudioStream(Stream):
    pass

cdef class SubtitleStream(Stream):
    
    cpdef decode(self, av.codec.Packet packet):
        cdef av.codec.SubtitleProxy proxy = av.codec.SubtitleProxy()
        cdef av.codec.Subtitle sub = None
        cdef int done = 0
        err_check(lib.avcodec_decode_subtitle2(self.codec.ctx, &proxy.struct, &done, &packet.struct))
        if done:
            return av.codec.Subtitle(self, proxy)
        

cdef class DataStream(Stream):
    pass

cdef class AttachmentStream(Stream):
    pass

cdef class NBStream(Stream):
    pass


# Handy alias.
open = Context