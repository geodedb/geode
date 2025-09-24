package main
import ("net"; "fmt")
func main() {
  c, _ := net.Dial("tcp", "127.0.0.1:7567")
  defer c.Close()
  // send HELLO
  c.Write([]byte{0x01,0x00}) // HELLO v0
  // read server caps + conformance digest...
  buf := make([]byte, 256); n, _ := c.Read(buf)
  fmt.Println("HELLO/OK:", buf[:n])
  // RUN_GQL "MATCH (n) RETURN n LIMIT 1"
  // ...
}
