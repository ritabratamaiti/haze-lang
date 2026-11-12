/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Frontend

/-!
# Entry Points for the Browser

The WebAssembly build of Haze, which the website's playground runs, calls these functions from
JavaScript through their C names. They check a source text the same way the `haze` command does
and return what it would print. They are pure functions, so the browser build needs neither a
file system nor threads.
-/

namespace Haze.Web

/-- Checks a source text and returns one JSON record per line, as `haze --json` prints them. -/
@[export haze_check_json]
def checkJson (src : String) : String :=
  (Haze.Frontend.runJson "main.hz" src {}).1

/-- Checks a source text and returns the messages that `haze` prints. -/
@[export haze_check_text]
def checkText (src : String) : String :=
  (Haze.Frontend.run "main.hz" src {}).1

end Haze.Web
