AirPlay interruption recovery and diagnostics

- Keep interruption recovery tied to the video that was actually playing. Old callbacks cannot restart a different video or a video you had already paused.
- Clear a stale interruption after playback successfully resumes, so a missing system interruption-ended event cannot keep later stall recovery disabled.
- Record the system's interruption reason, suspension flag, audio-session state, and network-path changes in the debug log to distinguish route loss from other interruptions when iOS provides that information.

These changes improve recovery and diagnosis. They do not establish or guarantee a fix for the underlying Vizio AirPlay disconnection, and reconnecting the receiver may still require selecting it in AirPlay.
