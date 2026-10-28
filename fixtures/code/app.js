// 前端脚本
const greet = (name) => `你好, ${name}!`;
export default class App {
  constructor() { this.count = 0x1F; }
  async run() { return await fetch('/api'); }
}
