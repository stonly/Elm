-- This is an early version of the touch library. It will likely grow to
-- include gestures that would be useful for both games and web-pages.
module Touch where

import Native.Touch as T

-- Every `Touch` has `xy` coordinates. It also has an identifier `id` to
-- distinguish one touch from another.
--
-- A touch also keeps info about the intial point and time of contact:
-- `x0`, `y0`, and `t0`. This helps compute more complicated gestures
-- like taps, drags, and swipes which need to know about timing or direction.
type Touch = { x:Int, y:Int, id:Int, x0:Int, y0:Int, t0:Time }

-- A list of ongoing touches.
touches : Signal [Touch]

-- The last position that was tapped. Default value is `{x=0,y=0}`.
-- Updates whenever the user taps the screen.
taps : Signal { x:Int, y:Int }
