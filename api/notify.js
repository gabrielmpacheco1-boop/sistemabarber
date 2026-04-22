// Vercel Serverless Function — Envio de notificações WhatsApp via Evolution API
// POST /api/notify

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const {
    tipo,   // 'novo_agendamento' | 'cancelamento'
    dados,  // { cliente_nome, servico_nome, barbeiro_nome, barbeiro_whatsapp, dono_whatsapp, data_hora }
  } = req.body;

  if (!tipo || !dados) {
    return res.status(400).json({ error: 'Campos obrigatórios ausentes' });
  }

  const {
    EVOLUTION_API_URL,
    EVOLUTION_API_KEY,
    EVOLUTION_INSTANCE,
  } = process.env;

  if (!EVOLUTION_API_URL || !EVOLUTION_API_KEY || !EVOLUTION_INSTANCE) {
    console.error('Evolution API env vars não configuradas');
    return res.status(500).json({ error: 'Configuração de notificação ausente' });
  }

  // Formata data/hora para exibição
  const dataHora = formatarDataHora(dados.data_hora);

  let mensagemBarbeiro, mensagemDono;

  if (tipo === 'novo_agendamento') {
    mensagemBarbeiro =
      `✂️ *Novo agendamento!*\n\n` +
      `👤 Cliente: ${dados.cliente_nome}\n` +
      `📋 Serviço: ${dados.servico_nome}\n` +
      `📅 Data/Hora: ${dataHora}\n\n` +
      `_AgendaBarber_`;

    mensagemDono =
      `📌 *Novo agendamento recebido!*\n\n` +
      `👤 Cliente: ${dados.cliente_nome}\n` +
      `📋 Serviço: ${dados.servico_nome}\n` +
      `✂️ Barbeiro: ${dados.barbeiro_nome}\n` +
      `📅 Data/Hora: ${dataHora}\n\n` +
      `_AgendaBarber_`;
  } else if (tipo === 'cancelamento') {
    mensagemBarbeiro =
      `❌ *Agendamento cancelado*\n\n` +
      `👤 Cliente: ${dados.cliente_nome}\n` +
      `📋 Serviço: ${dados.servico_nome}\n` +
      `📅 Data/Hora: ${dataHora}\n\n` +
      `_AgendaBarber_`;

    mensagemDono =
      `🚫 *Agendamento cancelado*\n\n` +
      `👤 Cliente: ${dados.cliente_nome}\n` +
      `📋 Serviço: ${dados.servico_nome}\n` +
      `✂️ Barbeiro: ${dados.barbeiro_nome}\n` +
      `📅 Data/Hora: ${dataHora}\n\n` +
      `_AgendaBarber_`;
  } else {
    return res.status(400).json({ error: `Tipo desconhecido: ${tipo}` });
  }

  const resultados = await Promise.allSettled([
    dados.barbeiro_whatsapp
      ? enviarMensagem(EVOLUTION_API_URL, EVOLUTION_API_KEY, EVOLUTION_INSTANCE, dados.barbeiro_whatsapp, mensagemBarbeiro)
      : Promise.resolve({ skipped: true }),
    dados.dono_whatsapp
      ? enviarMensagem(EVOLUTION_API_URL, EVOLUTION_API_KEY, EVOLUTION_INSTANCE, dados.dono_whatsapp, mensagemDono)
      : Promise.resolve({ skipped: true }),
  ]);

  const erros = resultados
    .filter(r => r.status === 'rejected')
    .map(r => r.reason?.message || 'Erro desconhecido');

  if (erros.length > 0) {
    console.error('Erros ao enviar WhatsApp:', erros);
  }

  return res.status(200).json({
    success: true,
    enviados: resultados.filter(r => r.status === 'fulfilled').length,
    erros,
  });
}

async function enviarMensagem(apiUrl, apiKey, instance, numero, mensagem) {
  // Normaliza número: remove tudo que não é dígito
  const numeroLimpo = String(numero).replace(/\D/g, '');

  const url = `${apiUrl}/message/sendText/${instance}`;

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'apikey': apiKey,
    },
    body: JSON.stringify({
      number: numeroLimpo,
      text: mensagem,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Evolution API ${res.status}: ${body}`);
  }

  return res.json();
}

function formatarDataHora(dataHoraStr) {
  try {
    const dt = new Date(dataHoraStr);
    return dt.toLocaleString('pt-BR', {
      timeZone: 'America/Sao_Paulo',
      weekday: 'long',
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return dataHoraStr;
  }
}
