open! Core

(* The build_info string can be either:
   - the empty string, from the default C function
   - a printed sexp, from the C function generated by jenga, which is parsable
     by the [t] type below *)
external generated_build_info : unit -> string = "generated_build_info"

(* The version_util can be either:
   - the empty string, from the default C function
   - "NO_VERSION_UTIL" from the C function generated by jenga
   - "repo1 rev40\nrepo2 rev40" from the C function generated by jenga

   The last two can be prefixed by [version_util_start_marker].  When the prefix is
   present, there is also enough padding for 4k worth of data. This allows us to rewrite
   binaries to insert the version util after linking.
*)
external generated_hg_version : unit -> string = "generated_hg_version"

let version_util_start_marker =
  (* This trick is to prevent the marker from occurring verbatim in the binary
     that uses [Expert.insert_version_util], so that we don't by accident rewrite our
     own code.
     [opaque_identity] is used to prevent the compiler from converting this computation
     into a literal, thus undoing this trick. We could split the marker in half instead,
     but that would make grepping hard for humans.
     Grep in the tree to see the place that generates this. *)
  (Sys.opaque_identity ( ^ )) "rUb71QgfHXXwnBWBoJfb0Sa3R60vihdV" ":"
;;

let parse_generated_hg_version = function
  | "" -> [ "NO_VERSION_UTIL" ]
  | generated_hg_version ->
    generated_hg_version
    |> String.chop_suffix_if_exists ~suffix:"\n"
    |> String.chop_prefix_if_exists ~prefix:version_util_start_marker
    |> String.split ~on:'\n'
    |> List.map ~f:(fun line ->
      match String.rsplit2 line ~on:' ' with
      | None -> line (* no version util *)
      | Some (repo, rev_status) ->
        (* For compability with downstream tools that might rely on this output format,
           and with [Version.parse].*)
        String.concat
          [ repo
          ; "_"
          ; String.prefix rev_status 12
          ; (* The revision can have a one-character '+' suffix. Keep it. *)
            (if String.length rev_status mod 2 = 1
             then String.suffix rev_status 1
             else "")
          ])
;;

let version_list = parse_generated_hg_version (generated_hg_version ())
let version = String.concat version_list ~sep:" "

module Version = struct
  type t =
    { repo : string
    ; version : string
    }
  [@@deriving compare, sexp_of]

  let parse1 version =
    match String.rsplit2 version ~on:'_' with
    | None -> error_s [%message "Could not parse version" version]
    | Some (repo, version) -> Ok { repo; version }
  ;;

  let parse_list l =
    (* We might get multiple such lines if we have multiple repos *)
    if List.exists l ~f:(String.( = ) "NO_VERSION_UTIL")
    then Ok None
    else
      List.map l ~f:parse1 |> Or_error.combine_errors |> Or_error.map ~f:(fun x -> Some x)
  ;;

  let parse_lines versions = parse_list (String.split_lines versions)
  let current_version () = ok_exn (parse_list version_list)

  let present = function
    | None -> error_s [%sexp "executable built without version util"]
    | Some x -> Ok x
  ;;

  let parse_list_present x = Or_error.bind ~f:present (parse_list x)
  let parse_lines_present x = Or_error.bind ~f:present (parse_lines x)
  let current_version_present () = present (current_version ())
end

module Expert = struct
  let pad str n = str ^ String.make (n - String.length str) '\000'

  let get_version_util ~contents_of_exe =
    let%map.Option i =
      String.substr_index contents_of_exe ~pattern:version_util_start_marker
    in
    String.slice contents_of_exe (i + String.length version_util_start_marker) (i + 4096)
    |> String.take_while ~f:(Char.( <> ) '\000')
    |> parse_generated_hg_version
    |> String.concat ~sep:" "
  ;;

  let replace_version_util ~contents_of_exe version_util =
    if String.mem version_util '\000' then failwith "version_util can't contain nul bytes";
    if String.length version_util > 4000
    (* using 4000 is easier than figuring the exact max length we support. *)
    then failwith "version_util must be shorter than 4000 bytes";
    (* There can be two places to rewrite, because apparently in the presence
       of weakdefs, both defs end up in the exe. *)
    match
      String.substr_index_all
        contents_of_exe
        ~may_overlap:false
        ~pattern:version_util_start_marker
    with
    | [] -> None
    | _ :: _ as l ->
      let b = Bytes.of_string contents_of_exe in
      List.iter l ~f:(fun i ->
        let start = i + String.length version_util_start_marker in
        let len = 4096 - String.length version_util_start_marker in
        assert (len > String.length version_util) (* this ensures we add a nul byte *);
        Stdlib.StdLabels.Bytes.blit_string
          ~src:(pad version_util len)
          ~src_pos:0
          ~dst:b
          ~dst_pos:start
          ~len);
      Some (Bytes.unsafe_to_string ~no_mutation_while_string_reachable:b)
  ;;

  (* Expert because we don't really want people to casually use this, so its contents can
     be trusted. *)
  let insert_version_util ~contents_of_exe (versions : Version.t list) =
    if List.is_empty versions
    then failwith "version_util must include at least one repository";
    if List.contains_dup ~compare:String.compare (List.map versions ~f:(fun v -> v.repo))
    then failwith "version_util must not contain duplicate repositories";
    let version_util =
      versions
      |> List.sort ~compare:Version.compare
      |> List.map ~f:(fun { repo; version } ->
        if not (String.mem repo '/')
        then failwith [%string "%{repo} doesn't look like a repo url"];
        (let version' = String.chop_suffix_if_exists version ~suffix:"+" in
         if (String.length version' = 40 || String.length version' = 64)
         && String.for_all version' ~f:Char.is_hex_digit_lower
         then ()
         else failwith [%string "%{version} doesn't look like a full hg version"]);
        repo ^ " " ^ version ^ "\n")
      |> String.concat
    in
    replace_version_util ~contents_of_exe version_util
  ;;

  let remove_version_util ~contents_of_exe =
    replace_version_util ~contents_of_exe "NO_VERSION_UTIL"
  ;;

  module For_tests = struct
    let count_pattern_occurrences ~contents_of_exe =
      List.length
        (String.substr_index_all
           contents_of_exe
           ~may_overlap:false
           ~pattern:version_util_start_marker)
    ;;
  end
end

module Application_specific_fields = struct
  type t = Sexp.t String.Map.t [@@deriving sexp]
end

module Time_with_limited_parsing = struct
  type t = Time_float.t * Sexp.t

  let t_of_sexp sexp =
    let str = string_of_sexp sexp in
    try
      match String.chop_suffix str ~suffix:"Z" with
      | None -> failwith "zone must be Z"
      | Some rest ->
        (match String.lsplit2 rest ~on:' ' with
         | None -> failwith "time must contain one space between date and ofday"
         | Some (date, ofday) ->
           let date = Date.t_of_sexp (sexp_of_string date) in
           let ofday = Time_float.Ofday.t_of_sexp (sexp_of_string ofday) in
           Time_float.of_date_ofday date ofday ~zone:Time_float.Zone.utc, sexp)
    with
    | Sexplib.Conv.Of_sexp_error (e, _) | e ->
      raise (Sexplib.Conv.Of_sexp_error (e, sexp))
  ;;

  let sexp_of_t_ref = ref (fun (_, sexp) -> sexp)
  let sexp_of_t time = !sexp_of_t_ref time
end

type t =
  { username : string option [@sexp.option]
  ; hostname : string option [@sexp.option]
  ; kernel : string option [@sexp.option]
  ; build_time : Time_with_limited_parsing.t option [@sexp.option]
  ; x_library_inlining : bool
  ; portable_int63 : bool
  ; dynlinkable_code : bool
  ; ocaml_version : string
  ; executable_path : string
  ; build_system : string
  ; allowed_projections : string list option [@sexp.option]
  ; with_fdo : (string * Md5.t option) option [@sexp.option]
  ; application_specific_fields : Application_specific_fields.t option [@sexp.option]
  }
[@@deriving sexp]

let build_info, build_info_as_sexp, t, build_system_supports_version_util =
  Exn.handle_uncaught_and_exit (fun () ->
    match generated_build_info () with
    | "" ->
      let t =
        { username = None
        ; hostname = None
        ; kernel = None
        ; build_time =
            Some (Time_with_limited_parsing.t_of_sexp (Atom "1970-01-01 00:00:00Z"))
        ; x_library_inlining = false
        ; portable_int63 = true
        ; dynlinkable_code = false
        ; ocaml_version = ""
        ; executable_path = ""
        ; build_system = ""
        ; allowed_projections = None
        ; with_fdo = None
        ; application_specific_fields = None
        }
      in
      let sexp = sexp_of_t t in
      let str = Sexp.to_string_mach sexp in
      str, sexp, t, false
    | str ->
      let sexp = Sexp.of_string str in
      let t = t_of_sexp sexp in
      str, sexp, t, true)
;;

let { username
    ; hostname
    ; kernel
    ; build_time = build_time_and_sexp
    ; x_library_inlining
    ; portable_int63 = _
    ; dynlinkable_code
    ; ocaml_version
    ; executable_path
    ; build_system
    ; allowed_projections
    ; with_fdo
    ; application_specific_fields
    }
  =
  t
;;

let build_time =
  match build_time_and_sexp with
  | None -> None
  | Some (time, _sexp) -> Some time
;;

let reprint_build_info sexp_of_time =
  Ref.set_temporarily
    Time_with_limited_parsing.sexp_of_t_ref
    (fun (time, _) -> sexp_of_time time)
    ~f:(fun () -> Sexp.to_string (sexp_of_t t))
;;

let compiled_for_speed = x_library_inlining && not dynlinkable_code

module For_tests = struct
  let parse_generated_hg_version = parse_generated_hg_version
end

let arg_spec =
  [ ( "-version"
    , Arg.Unit
        (fun () ->
           List.iter version_list ~f:print_endline;
           exit 0)
    , " Print the hg revision of this build and exit" )
  ; ( "-build_info"
    , Arg.Unit
        (fun () ->
           print_endline build_info;
           exit 0)
    , " Print build info as sexp and exit" )
  ]
;;
