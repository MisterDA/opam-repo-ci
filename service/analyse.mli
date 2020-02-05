module Analysis : sig
  type t

  val opam_files : t -> string list

  val of_dir : job:Current.Job.t -> Fpath.t -> (t, [ `Msg of string ]) result Lwt.t
end

val examine : Current_git.Commit.t Current.t -> Analysis.t Current.t
(** [examine src] returns a list of "*.opam" files in [src]. *)
