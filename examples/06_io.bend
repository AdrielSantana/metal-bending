import Base

def greet(name: String) -> IO(String):
  do IO<String>:
    IO.sleep(200)
    return "Hello, " ++ name

def main() -> IO(Unit):
  do IO<Unit>:
    name : String <- IO.try(String, IO.get_env("USER"))
    chan : Chan(String) <- IO.fork(String, greet(name))
    IO.print("Waiting...")
    text : String <- IO.join(String, chan)
    IO.print(text)
