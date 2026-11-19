// A fake OpenAI-compatible AI provider for offline testing.
// It answers quiz/flashcard prompts with valid JSON and everything else with text,
// streaming or not, so the whole chain (app → FreeLLMAPI → provider) can be tested
// without internet access or real API keys.
import http from 'node:http';
const PORT = Number(process.env.MOCK_PORT || 4010);

function answerFor(messages) {
  const last = String(messages.at(-1)?.content || '');
  if (/"questions"/.test(last)) return JSON.stringify({ questions: [
    { question: 'Where does photosynthesis mainly happen?', options: ['Mitochondria', 'Chloroplasts', 'Nucleus', 'Ribosomes'], answer: 1, explanation: 'Chloroplasts contain chlorophyll.' },
    { question: 'Which gas is released?', options: ['Oxygen', 'Nitrogen', 'CO2', 'Hydrogen'], answer: 0, explanation: 'Water splitting releases O2.' },
    { question: 'Which enzyme fixes CO2?', options: ['Amylase', 'RuBisCO', 'Lipase', 'Pepsin'], answer: 1, explanation: 'RuBisCO fixes CO2 in the Calvin cycle.' },
  ] });
  if (/"cards"/.test(last)) return '```json\n' + JSON.stringify({ cards: [
    { front: 'Chlorophyll', back: 'Green pigment that absorbs light' },
    { front: 'Calvin cycle', back: 'Light-independent reactions in the stroma' },
    { front: 'Photolysis', back: 'Splitting of water by light' },
    { front: 'Limiting factor', back: 'The factor in shortest supply that limits rate' },
  ] }) + '\n```';
  return '## Summary\n- Plants turn **light energy** into glucose.\n- It happens in the *chloroplasts*.\n- Oxygen is a by-product.';
}

http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    if (req.method === 'GET' && req.url.endsWith('/models')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ object: 'list', data: [{ id: 'mock-tutor', object: 'model' }] }));
    }
    if (!req.url.endsWith('/chat/completions')) { res.writeHead(404); return res.end('{}'); }
    const body = JSON.parse(raw || '{}');
    const text = answerFor(body.messages || []);
    const base = { id: 'mock-1', object: 'chat.completion', created: Math.floor(Date.now() / 1000), model: body.model || 'mock-tutor' };
    if (!body.stream) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ ...base, choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 } }));
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const parts = text.match(/[\s\S]{1,12}/g) || [];
    let i = 0;
    const tick = setInterval(() => {
      if (i < parts.length) {
        res.write(`data: ${JSON.stringify({ ...base, object: 'chat.completion.chunk', choices: [{ index: 0, delta: i === 0 ? { role: 'assistant', content: parts[i] } : { content: parts[i] }, finish_reason: null }] })}\n\n`);
        i++;
      } else {
        clearInterval(tick);
        res.write(`data: ${JSON.stringify({ ...base, object: 'chat.completion.chunk', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 } })}\n\n`);
        res.end('data: [DONE]\n\n');
      }
    }, 10);
  });
}).listen(PORT, '127.0.0.1', () => console.log(`mock provider on http://127.0.0.1:${PORT}/v1`));
