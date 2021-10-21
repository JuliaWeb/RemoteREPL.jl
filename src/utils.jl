using Base: LibuvStream, StatusEOF,
    start_reading, stop_reading,
    preserve_handle, unpreserve_handle,
    iolock_begin, iolock_end

# Based on Base.wait_readnb()

if VERSION < v"1.8"

function try_wait_readnb(x::LibuvStream, nb::Int)
    # fast path before iolock acquire
    bytesavailable(x.buffer) >= nb && return
    open = isopen(x) # must precede readerror check
    x.readerror === nothing || throw(x.readerror)
    open || return
    iolock_begin()
    # repeat fast path after iolock acquire, before other expensive work
    bytesavailable(x.buffer) >= nb && (iolock_end(); return)
    open = isopen(x)
    x.readerror === nothing || throw(x.readerror)
    open || (iolock_end(); return)
    # now do the "real" work
    oldthrottle = x.throttle
    preserve_handle(x)
    lock(x.cond)
    try
        # while bytesavailable(x.buffer) < nb
        if bytesavailable(x.buffer) < nb
            x.readerror === nothing || throw(x.readerror)
            x.throttle = max(nb, x.throttle)
            start_reading(x) # ensure we are reading
            iolock_end()
            wait(x.cond)  # Need to notify this on cancel.
            unlock(x.cond)
            iolock_begin()
            lock(x.cond)
        end
    finally
        if isempty(x.cond)
            stop_reading(x) # stop reading iff there are currently no other read clients of the stream
        end
        if oldthrottle <= x.throttle <= nb
            # if we're interleaving readers, we might not get back to the "original" throttle
            # but we consider that an acceptable "risk", since we can't be quite sure what the intended value is now
            x.throttle = oldthrottle
        end
        unpreserve_handle(x)
        unlock(x.cond)
    end
    iolock_end()
    nothing
end

end
