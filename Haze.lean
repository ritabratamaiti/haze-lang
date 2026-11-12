/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Core
import Haze.Syntax
import Haze.Elab
import Haze.Kernel.Check
import Haze.Kernel.Eval
import Haze.Kernel.Verify
import Haze.Json
import Haze.Frontend
import Haze.Web
import Haze.Theory

/-!
# Haze

This module imports the whole Haze library. A source file is parsed by `Haze.Syntax`,
elaborated by `Haze.Elab`, and checked and evaluated by the kernel in `Haze.Kernel`.
`Haze.Frontend` drives these steps one declaration at a time and reports the results.
-/
