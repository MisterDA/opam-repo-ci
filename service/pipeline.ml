open Current.Syntax
open Ocaml_ci

module Git = Current_git
module Github = Current_github
module Docker = Current_docker.Default
module Common = Ocaml_ci_api.Common

let default_compiler = "4.10"

let weekly = Current_cache.Schedule.v ~valid_for:(Duration.of_day 7) ()

(* Link for GitHub statuses. *)
let url ~owner ~name ~hash = Uri.of_string (Printf.sprintf "http://147.75.80.95/github/%s/%s/commit/%s" owner name hash)

let github_status_of_state ~head result =
  let+ head = head
  and+ result = result in
  let { Github.Repo_id.owner; name } = Github.Api.Commit.repo_id head in
  let hash = Github.Api.Commit.hash head in
  let url = url ~owner ~name ~hash in
  match result with
  | Ok _              -> Github.Api.Status.v ~url `Success ~description:"Passed"
  | Error (`Active _) -> Github.Api.Status.v ~url `Pending
  | Error (`Msg _)    -> Github.Api.Status.v ~url `Failure ~description:"Failed"

let set_active_refs ~repo xs =
  let+ repo = repo
  and+ xs = xs in
  let repo = Github.Api.Repo.id repo in
  Index.set_active_refs ~repo (
    xs |> List.map @@ fun x ->
    let commit = Github.Api.Commit.id x in
    let gref = Git.Commit_id.gref commit in
    let hash = Git.Commit_id.hash commit in
    (gref, hash)
  );
  xs

let status_sep = String.make 1 Common.status_sep

module Docker1 :
  (S.DOCKER_CONTEXT with type source = [ `Git of Current_git.Commit.t Current.t | `No_context ]) =
  Conf.Builder_amd1
module Build1 = Opam_build.Make (Docker1)

type job = (string * ([`Built | `Checked] Current.t * Current.job_id option Current.t))
type stage =
  | Skip
  | Stage of job
  | DynamicStages of stage Current.t list

let job_id ?(kind=`Built) build =
  let job = Current.map (fun _ -> kind) build in
  (job, Current.Analysis.metadata build)

let build_with_docker ~analysis source : stage Current.t =
  let analysis_job = Stage ("(analysis)", job_id ~kind:`Checked analysis) in
  let+ analysis = Current.state ~hidden:true analysis in
  match analysis with
  | Error _ -> analysis_job
  | Ok analysis ->
      let pkgs = Analyse.Analysis.opam_files analysis in
      let build ~revdeps name variant =
        let base = Build1.base ~schedule:weekly ~variant in
        List.map (fun pkg ->
          let prefix = pkg^status_sep^name in
          let image = Build1.v ~revdep:None ~with_tests:false ~pkg source base in
          let tests =
            let+ state = Current.state ~hidden:true image in
            match state with
            | Error _ -> Skip
            | Ok _ -> Stage (prefix^status_sep^"tests", job_id (Build1.v ~revdep:None ~with_tests:true ~pkg source base))
          in
          let revdeps =
            if revdeps then
              let+ state = Current.state ~hidden:true image in
              match state with
              | Error _ -> Skip
              | Ok _ ->
                  let prefix = prefix^status_sep^"revdeps" in
                  let revdeps_job =
                    Docker1.pread image ~args:["opam";"list";"-s";"--color=never";"--depends-on";pkg;"--installable";"--all-versions";"--depopts"]
                  in
                  let revdeps =
                    let+ revdeps = Current.state ~hidden:true revdeps_job in
                    match revdeps with
                    | Error _ -> Skip
                    | Ok revdeps ->
                        DynamicStages (
                          String.split_on_char '\n' revdeps |>
                          List.filter (fun pkg -> not (String.equal pkg "")) |>
                          List.map (fun revdep ->
                            let prefix = prefix^status_sep^revdep in
                            let revdep = Some revdep in
                            let image = Build1.v ~revdep ~with_tests:false ~pkg source base in
                            let tests =
                              let+ state = Current.state ~hidden:true image in
                              match state with
                              | Error _ -> Skip
                              | Ok _ -> Stage (prefix^status_sep^"tests", job_id (Build1.v ~revdep ~with_tests:true ~pkg source base))
                            in
                            Current.return (DynamicStages [Current.return (Stage (prefix, job_id image)); tests])
                          )
                        )
                  in
                  DynamicStages [Current.return (Stage (prefix, job_id revdeps_job)); revdeps]
            else
              Current.return Skip
          in
          Current.return (DynamicStages [Current.return (Stage (prefix, job_id image)); tests; revdeps])
        ) pkgs
      in
      let stages =
        List.concat [
          build ~revdeps:true "4.10" "debian-10-ocaml-4.10";
          build ~revdeps:true "4.09" "debian-10-ocaml-4.09";
          build ~revdeps:true "4.08" "debian-10-ocaml-4.08";
          build ~revdeps:true "4.07" "debian-10-ocaml-4.07";
          build ~revdeps:true "4.06" "debian-10-ocaml-4.06";
          build ~revdeps:true "4.05" "debian-10-ocaml-4.05";
          build ~revdeps:true "4.04" "debian-10-ocaml-4.04";
          build ~revdeps:true "4.03" "debian-10-ocaml-4.03";
          build ~revdeps:true "4.02" "debian-10-ocaml-4.02";
        ] @
        List.fold_left (fun builds -> function
          | `Debian `V10 -> builds (* Skip debian 10 as it was already tested in the main phase *)
          | `OracleLinux _ -> builds (* Not supported by opam-depext *)
          | distro ->
              let distro = Dockerfile_distro.tag_of_distro distro in
              let variant = distro^"-ocaml-"^default_compiler in
              build ~revdeps:false distro variant
        ) [] (Dockerfile_distro.active_distros `X86_64)
      in
      DynamicStages [Current.return analysis_job; Current.return (DynamicStages stages)]

let list_errors ~ok errs =
  let groups =  (* Group by error message *)
    List.sort compare errs |> List.fold_left (fun acc (msg, l) ->
        match acc with
        | (m2, ls) :: acc' when m2 = msg -> (m2, l :: ls) :: acc'
        | _ -> (msg, [l]) :: acc
      ) []
  in
  Error (`Msg (
      match groups with
      | [] -> assert false
      | [ msg, _ ] when ok = 0 -> msg (* Everything failed with the same error *)
      | [ msg, ls ] -> Fmt.strf "%a failed: %s" Fmt.(list ~sep:(unit ", ") string) ls msg
      | _ ->
        (* Multiple error messages; just list everything that failed. *)
        let pp_label f (_, l) = Fmt.string f l in
        Fmt.strf "%a failed" Fmt.(list ~sep:(unit ", ") pp_label) errs
    ))

let summarise results =
  results
  |> List.map (fun (label, build) ->
      let+ result = Current.state build ~hidden:true in
      (label, result)
    )
  |> Current.list_seq
  |> Current.map @@ fun results ->
  results |> List.fold_left (fun (ok, pending, err, skip) -> function
    | _, Ok `Checked -> (ok, pending, err, skip)  (* Don't count lint checks *)
    | _, Ok `Built -> (ok + 1, pending, err, skip)
    | l, Error `Msg m when Astring.String.is_prefix ~affix:"[SKIP]" m -> (ok, pending, err, (m, l) :: skip)
    | l, Error `Msg m -> (ok, pending, (m, l) :: err, skip)
    | _, Error `Active _ -> (ok, pending + 1, err, skip)
  ) (0, 0, [], [])
  |> fun (ok, pending, err, skip) ->
  if pending > 0 then Error (`Active `Running)
  else match ok, err, skip with
    | 0, [], skip -> list_errors ~ok:0 skip (* Everything was skipped - treat skips as errors *)
    | _, [], _ -> Ok ()                     (* No errors and at least one success *)
    | ok, err, _ -> list_errors ~ok err     (* Some errors found - report *)

let get_prs repo =
  let+ refs =
    Current.component "Get PRs" |>
    let> (api, repo) = repo in
    Github.Api.refs api repo
  in
  Github.Api.Ref_map.fold begin fun key head acc ->
    match key with
    | `Ref _ -> acc (* Skip branches, only check PRs *)
    | `PR _ -> head :: acc
  end refs []

let rec get_jobs_aux f builds =
  let* builds = builds in
  match builds with
  | Skip ->
      Current.return []
  | Stage job ->
      let+ job = f job in
      [job]
  | DynamicStages stages ->
      List.fold_left (fun acc stage ->
        let+ stage = get_jobs_aux f stage
        and+ acc = acc in
        stage @ acc
      ) (Current.return []) stages

let summarise builds =
  let get_job (variant, (build, _job)) = Current.return (variant, build) in
  Current.component "summarise" |>
  let** jobs = get_jobs_aux get_job builds in
  summarise jobs

let get_jobs builds =
  let get_job (variant, (_build, job)) = Current.map (fun job -> (variant, job)) job in
  get_jobs_aux get_job builds

let local_test repo () =
  let src = Git.Local.head_commit repo in
  let analysis = Analyse.examine src in
  Current.component "summarise" |>
  let** result =
    build_with_docker ~analysis (`Git src) |>
    summarise
  in
  Current.of_output result

let v ~app () =
  Github.App.installations app |> Current.list_iter (module Github.Installation) @@ fun installation ->
  let repos = Github.Installation.repositories installation in
  repos |> Current.list_iter (module Github.Api.Repo) @@ fun repo ->
  let prs = get_prs repo |> set_active_refs ~repo in
  prs |> Current.list_iter (module Github.Api.Commit) @@ fun head ->
  let src = Git.fetch (Current.map Github.Api.Commit.id head) in
  let analysis = Analyse.examine src in
  let builds = build_with_docker ~analysis (`Git src) in
  let summary = summarise builds in
  let status =
    let+ summary = summary in
    match summary with
    | Ok () -> `Passed
    | Error (`Active `Running) -> `Pending
    | Error (`Msg _) -> `Failed
  in
  let index =
    let+ commit = head
    and+ jobs = get_jobs builds
    and+ status = status in
    let repo = Current_github.Api.Commit.repo_id commit in
    let hash = Current_github.Api.Commit.hash commit in
    Index.record ~repo ~hash ~status jobs
  and set_github_status =
    summary
    |> github_status_of_state ~head
    |> Github.Api.Commit.set_status head "opam-ci"
  in
  Current.all [index; set_github_status]
