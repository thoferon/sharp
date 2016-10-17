open Sharp_category

type time = float

module Event = struct
  type 'a t =
    | Cons of time * 'a * 'a t
    | Stop of 'a t option ref

  let create () = Stop (ref None)

  let rec add es t x = match es with
    | Cons (t', _, es') when t != t' -> add es' t x
    | Cons (t', _, es') -> add es' (t +. epsilon_float) x
    | Stop r ->
       match !r with
       | None -> r := Some (Cons (t, x, (create ()))); t
       | Some es' -> add es' t x

  let rec at es t = match es with
    | Cons (t', x, _) when t = t' -> Some x
    | Cons (t', _, _) when t > t' -> None
    | Cons (_, _, es') -> at es' t
    | Stop r ->
       match !r with
       | None     -> None
       | Some es' -> at es' t

  let rec after es t = match es with
    | Cons (t', _, es') when t >= t' -> after es' t
    | Cons (_, _, _) -> es
    | Stop r ->
       match !r with
       | None     -> es
       | Some es' -> after es' t
end

module type Behaviour_base_S = sig
  type 'a t
  type 'a event_callback = 'a -> time
  type 'a event = 'a option t * 'a event_callback

  val at : 'a t -> time -> 'a * 'a t
  val time : time t

  val map : 'a t -> f:('a -> 'b) -> 'b t
  val pure : 'a -> 'a t
  val apply : ('a -> 'b) t -> 'a t -> 'b t
  val join : 'a t t -> 'a t

  val ( <$?> ) : ('a -> 'b) -> 'a option t -> 'b option t
  val ( <*?> ) : ('a -> 'b) option t -> 'a option t -> 'b option t
  val ( <|> ) : 'a option t -> 'a option t -> 'a option t

  val event : unit -> 'a event
  val to_behaviour : 'a event -> 'a option t
  val to_behavior : 'a event -> 'a option t
  val trigger : 'a event -> 'a -> unit

  val on : 'a option t -> init:'b -> f:('b -> 'a -> 'b) -> 'b t
  val last : 'a option t -> init:'a -> 'a t
  val toggle : 'a option t -> init:bool -> bool t
  val count : ?init:int -> 'a option t -> int t
  val upon : ?init:'a -> 'b option t -> 'a t -> 'a t

  val fold : ('a -> 'b -> 'a) -> 'a -> 'b t -> 'a t
end

module Behaviour_base = struct
  type 'a t = B of (time -> 'a * 'a t)
  type 'a event_callback = 'a -> time
  type 'a event = 'a option t * 'a event_callback

  let at (B f) t = f t

  let time =
    let rec b = B (fun t -> (t, b)) in b

  let rec map (B fa) ~f =
    let fb t =
      let (a, ba) = fa t in (f a, map ~f ba)
    in B fb

  let pure a = let rec b = B (fun _ -> (a, b)) in b

  let rec apply (B bf) (B ba) =
    let g t =
      let (f, bf') = bf t in
      let (a, ba') = ba t in
      (f a, apply bf' ba')
    in B g

  let rec join (B fba) =
    let f' t =
      let (B fa, bba) = fba t in
      let (a,    _)   = fa  t in
      (a, join bba)
    in B f'

  let map_opt f = function
    | None   -> None
    | Some x -> Some (f x)

  let app_opt fopt aopt = match fopt, aopt with
    | Some f, Some a -> Some (f a)
    | _ -> None

  let ( <$?> ) f b = map ~f:(map_opt f) b
  let rec ( <*?> ) bf ba = apply (map ~f:app_opt bf) ba

  let rec ( <|> ) (B fa) (B fb) =
    let f t =
      let (a, ba) = fa t in
      let (b, bb) = fb t in
      let c = match a with
        | Some _ -> a
        | _ -> b
      in (c, ba <|> bb)
    in B f

  let event () =
    let module E = Event in
    let tip = ref (E.create ()) in
    let rec b =
      let f t =
        let e = !tip in
        let x = E.at e t in
        tip := E.after e t; (x, b)
      in B f
    in
    let add x = E.add !tip (Sys.time ()) x in
    (b, add)

  let to_behaviour (b, _) = b
  let to_behavior = to_behaviour
  let trigger (_, c) x = let _ = c x in ()

  let rec on (B fa) ~init ~f =
    let f' t =
      match fa t with
      | (None,   b) -> (init, on ~init ~f b)
      | (Some a, b) ->
         let init' = f init a in (init',  on ~init:init' ~f b)
    in B f'

  let last   b ~init   = on b ~init ~f:(fun _ x -> x)
  let toggle b ~init   = on b ~init ~f:(fun i _ -> not i)
  let count  ?(init=0) = on ~init ~f:(fun i _ -> i + 1)

  let rec upon ?init (B fa) (B fb) =
    let f t =
      let (a, ba) = fa t in
      let (b, bb) = fb t in
      match a with
      | Some _ -> (b, upon ~init:b ba bb)
      | None   ->
         let value = match init with
           | Some x -> x
           | None   -> b
         in (value, upon ~init:value ba bb)
    in B f

  let rec fold f init (B fa) =
    let f' t =
      let (a, ba) = fa t     in
      let init'   = f init a in
      (init', fold f init' ba)
    in B f'
end

module Behaviour = struct
  module Base = Behaviour_base
  include Base
  include Monad.MakeNoInfix(Base)
  module Infix = Monad.Make(Base)
end

module Behavior = Behaviour

module type Network_base_S = sig
  type 'a t
  val start : 'a t -> unit -> unit
  val add_funnel : ((time -> unit) -> unit -> unit) -> unit t
  val add_sink : (time -> unit) -> unit t

  val map : 'a t -> f:('a -> 'b) -> 'b t
  val pure : 'a -> 'a t
  val apply : ('a -> 'b) t -> 'a t -> 'b t
  val join : 'a t t -> 'a t

  val perform_state : 'a Behaviour.t -> init:'b -> f:('b -> 'a -> 'b) -> unit t
  val perform : 'a Behaviour.t -> f:('a -> unit) -> unit t
  val react :
    'a Behaviour.event -> 'b Behaviour.t -> f:('a -> 'b -> unit) -> unit t

  val initially : (unit -> unit) -> unit t
  val finally : (unit -> unit) -> unit t
end

module Network_base : Network_base_S = struct
  (* Receive a function to signal a new event and return a function to
   * disconnect the funnel *)
  type funnel = F of ((time -> unit) -> (unit -> unit))

  type sink = S of (time -> unit)

  type 'a t =
    { value       : 'a
    ; funnels     : funnel list
    ; sinks       : sink list
    ; initialiser : unit -> unit
    ; finaliser   : unit -> unit
    }

  (* helper for start *)
  let rec connect acc signal = function
    | [] -> acc
    | F f :: fs' ->
       let disconnect = f signal in
       let acc' () = acc (disconnect ()) in
       connect acc' signal fs'

  let rec flush_sinks t = function
    | [] -> ()
    | S s :: sinks' -> s t; flush_sinks t sinks'

  let start { funnels; sinks; initialiser; finaliser } =
    let started = ref false in
    let signal t = flush_sinks t sinks in
    let proxy_signal t = if !started then signal t else () in
    let disconnect = connect (fun () -> finaliser ()) proxy_signal funnels in
    started := true; initialiser (); signal (Sys.time ()); disconnect

  let empty =
    { value       = ()
    ; funnels     = []
    ; sinks       = []
    ; initialiser = (fun () -> ())
    ; finaliser   = (fun () -> ())
    }

  let add_funnel f = { empty with funnels = [F f] }
  let add_sink   s = { empty with sinks   = [S s] }

  let map ({ value } as network) ~f = { network with value = f value }

  let pure x = { empty with value = x }

  let apply { value = f; funnels; sinks; initialiser; finaliser }
            { value = x; funnels = funnels'; sinks = sinks';
              initialiser = initialiser'; finaliser = finaliser' } =
    { value       = f x
    ; funnels     = funnels @ funnels'
    ; sinks       = sinks @ sinks'
    ; initialiser = (fun () -> initialiser' (initialiser ()))
    ; finaliser   = (fun () -> finaliser' (finaliser ()))
    }

  let join { value; funnels; sinks; initialiser; finaliser } =
    let { value = value'; funnels = funnels'; sinks = sinks';
          initialiser = initialiser'; finaliser = finaliser' } = value
    in
    { value       = value'
    ; funnels     = funnels @ funnels'
    ; sinks       = sinks @ sinks'
    ; initialiser = (fun () -> initialiser' (initialiser ()))
    ; finaliser   = (fun () -> finaliser' (finaliser ()))
    }

  let perform_state b ~init ~f =
    let bref     = ref b    in
    let stateref = ref init in
    let s t =
      let (x, b') = Behaviour.at !bref t in
      let state   = !stateref in
      bref := b';
      let state' = f state x in
      stateref := state'
    in add_sink s

  let perform b ~f = perform_state ~init:() b ~f:(fun () x -> f x; ())

  let react e b ~f =
    perform (Behaviour.apply (Behaviour.map ~f:(fun x y -> (x, y)) b)
                             (Behaviour.to_behaviour e))
            (fun (bval, eval_opt) -> match eval_opt with
                                 | None -> ()
                                 | Some eval -> f eval bval)

  let initially f = { empty with initialiser = f }
  let finally   f = { empty with finaliser   = f }
end

module type Network_extra_S = sig
  type 'a t
  val event : (('a -> unit) -> (unit -> unit)) -> 'a Behaviour.event t
  val unbound_event : unit -> 'a Behaviour.event t
end

module Network_extra (M : sig
                        include Monad.NoInfix
                        val add_funnel :
                          ((time -> unit) -> unit -> unit) -> unit t
                      end) = struct
  let event (connect : ('a -> unit) -> unit -> unit) =
    let (b, add) = Behaviour.event () in
    let connect' signal =
      let add' x =
        let t = add x in signal t
      in connect add'
    in
    M.bind (M.add_funnel connect') (fun _ -> M.pure (b, add))

  let unbound_event () =
    let (b, add) = Behaviour.event () in
    let signalref = ref (fun _ -> ()) in
    let connect signal =
      signalref := signal;
      fun () -> signalref := fun _ -> ()
    in
    let add' x =
      let t = add x in (!signalref) t; t
    in M.bind (M.add_funnel connect) (fun _ -> M.pure (b, add'))
end

module Network = struct
  module Base = Network_base
  include Base
  include Monad.MakeNoInfix(Base)

  include Network_extra(struct
                         include Base
                         include Monad.MakeNoInfix(Base)
                       end)

  module Infix = Monad.Make(Base)
end
