type 'a entry =
  { deadline : int64
  ; value : 'a
  ; mutable index : int (* Position in [data], or [-1] once removed. *)
  }

type 'a t =
  { mutable data : 'a entry array
  ; mutable size : int
  }

let create () = { data = [||]; size = 0 }
let length t = t.size

let set t i e =
  t.data.(i) <- e;
  e.index <- i

let swap t i j =
  let e = t.data.(i) in
  set t i t.data.(j);
  set t j e

let rec sift_up t i =
  let parent = (i - 1) / 2 in
  if i > 0 && t.data.(i).deadline < t.data.(parent).deadline
  then begin
    swap t i parent;
    sift_up t parent
  end

let rec sift_down t i =
  let l = (2 * i) + 1 in
  let r = l + 1 in
  let smallest =
    if l < t.size && t.data.(l).deadline < t.data.(i).deadline then l else i
  in
  let smallest =
    if r < t.size && t.data.(r).deadline < t.data.(smallest).deadline
    then r
    else smallest
  in
  if smallest <> i
  then begin
    swap t i smallest;
    sift_down t smallest
  end

let add t deadline value =
  let e = { deadline; value; index = -1 } in
  if t.size = Array.length t.data
  then begin
    let data = Array.make (max 16 (2 * t.size)) e in
    Array.blit t.data 0 data 0 t.size;
    t.data <- data
  end;
  set t t.size e;
  t.size <- t.size + 1;
  sift_up t e.index;
  e

let min_deadline t = if t.size = 0 then None else Some t.data.(0).deadline

let remove t e =
  let i = e.index in
  if i >= 0
  then begin
    e.index <- -1;
    t.size <- t.size - 1;
    if i < t.size
    then begin
      let moved = t.data.(t.size) in
      set t i moved;
      sift_up t i;
      sift_down t moved.index
    end;
    (* Don't let the vacated slot keep the removed value alive. *)
    if t.size = 0 then t.data <- [||] else t.data.(t.size) <- t.data.(0)
  end

let pop_expired t now =
  if t.size > 0 && t.data.(0).deadline <= now
  then begin
    let e = t.data.(0) in
    remove t e;
    Some e.value
  end
  else None
