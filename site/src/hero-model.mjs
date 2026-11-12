// The model behind the home page's animation. The site build precomputes its results with it, and
// the page checks it live as the controls change.
export const heroModel = (loss, idempotent) => `enum Phase = Sending | Waiting | Done | GaveUp
def loss : Num := ${loss}

system Client(idempotent : Bool) {
  var phase : Phase := Sending
  var attempts : Num := 0
  var charges : Num := 0
  step {
    match phase {
      Sending => {
        attempts := attempts + 1
        if flip(loss) { phase := Waiting }
        else {
          if not idempotent or charges == 0 { charges := charges + 1 }
          if flip(loss) { phase := Waiting } else { phase := Done }
        }
      }
      Waiting => { if attempts < 3 { phase := Sending } else { phase := GaveUp } }
      _ => skip
    }
  }
}

#prob Client(${idempotent}) |= eventually charges >= 2
`;
