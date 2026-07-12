(** Staleness detection for managed instances (idea I010).

    A managed instance runs an outer [c2c start] supervisor whose executable
    image is the [c2c] binary it started from. After [just install-all] does
    an atomic rm+cp, the on-disk path points at a NEW inode while the running
    process keeps executing the OLD (now unlinked-but-open) image. This module
    answers: "is the image a running pid executes stale relative to the
    currently-installed binary?" — the version-aware skip primitive the
    [restart-stale] command builds on. *)

type verdict =
  | Current
      (** The running image is byte-identical to the installed binary. *)
  | Stale
      (** The running image differs from the installed binary — the process is
          executing old code and would benefit from a restart. *)
  | Unknown of string
      (** Identity could not be determined (process gone, [/proc] entry
          unreadable, or the images could not be hashed). The string is a
          human-readable reason. Callers should skip Unknown instances unless
          explicitly forced. *)

val proc_exe : int -> string
(** [proc_exe pid] is the [/proc/<pid>/exe] path. *)

val compare_images : target:string -> installed:string -> verdict
(** [compare_images ~target ~installed] is the testable core of {!classify}: it
    compares two executable-image paths by device+inode (fast path) then, on an
    inode mismatch, by file size and SHA-256 content. Equal content ⇒ [Current];
    differing content ⇒ [Stale]; unreadable/un-hashable ⇒ [Unknown]. *)

val classify : installed_exe:string -> int -> verdict
(** [classify ~installed_exe pid] compares the executable image of [pid]
    against [installed_exe] (typically ["/proc/self/exe"] — the freshly
    exec'd, therefore current, binary running this command).

    Fast path: same device+inode ⇒ [Current] (definitely the same image).
    On an inode mismatch (which [just install-all] causes on EVERY install,
    even when the code is unchanged), it confirms by content: file size first
    (cheap), then SHA-256. Equal content ⇒ [Current] (an identical reinstall,
    not worth restarting); differing content ⇒ [Stale]. Any unreadable or
    un-hashable image ⇒ [Unknown]. *)

val verdict_label : verdict -> string
(** Short lowercase label: ["current"] / ["stale"] / ["unknown"]. *)
