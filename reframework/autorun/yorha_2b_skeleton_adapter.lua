-- Compatibility retirement marker for the former 2B-only test companion.
-- Independent skeletons are now declared in wardrobe manifests and applied by
-- the wardrobe plugin itself (OWOTSAppearanceLab, UpdateMotion joint rebase).
-- The installer backs up the old script before replacing it with this inert
-- marker. A complete game restart is required; never hot-reload scripts while
-- an old skeleton lease is active.
return { retired = true, replacement = "OWOTSAppearanceLab (built-in skeleton rebase)" }
