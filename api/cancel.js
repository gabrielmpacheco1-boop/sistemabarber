// Vercel Serverless Function — Cancelamento de agendamento por token
// GET /api/cancel?token=<token_cancelamento>

export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const token = req.query.token || req.body?.token;

  if (!token || typeof token !== 'string' || token.length < 10) {
    return res.status(400).json({ success: false, message: 'Token inválido.' });
  }

  const { SUPABASE_URL, SUPABASE_SERVICE_KEY } = process.env;

  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
    return res.status(500).json({ success: false, message: 'Configuração do servidor ausente.' });
  }

  try {
    // Busca o agendamento pelo token
    const agendamento = await supaFetch(
      SUPABASE_URL,
      SUPABASE_SERVICE_KEY,
      `agendamentos?token_cancelamento=eq.${encodeURIComponent(token)}&select=*,barbeiros(nome,telefone_whatsapp),servicos(nome),barbearias(whatsapp_dono)`
    );

    if (!agendamento?.length) {
      return res.status(404).json({ success: false, message: 'Agendamento não encontrado.' });
    }

    const a = agendamento[0];

    if (a.status === 'cancelado') {
      return res.status(200).json({ success: false, message: 'Este agendamento já foi cancelado.' });
    }

    // Verifica se o horário já passou
    const dataHora = new Date(a.data_hora);
    if (dataHora < new Date()) {
      return res.status(400).json({ success: false, message: 'Não é possível cancelar um agendamento que já ocorreu.' });
    }

    // Cancela o agendamento
    await supaFetch(
      SUPABASE_URL,
      SUPABASE_SERVICE_KEY,
      `agendamentos?id=eq.${a.id}`,
      { method: 'PATCH', body: JSON.stringify({ status: 'cancelado' }) }
    );

    // Notifica via WhatsApp (fire and forget)
    const baseUrl = process.env.VERCEL_URL
      ? `https://${process.env.VERCEL_URL}`
      : 'http://localhost:3000';

    fetch(`${baseUrl}/api/notify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tipo: 'cancelamento',
        dados: {
          cliente_nome:      a.cliente_nome,
          servico_nome:      a.servicos?.nome || '—',
          barbeiro_nome:     a.barbeiros?.nome || '—',
          barbeiro_whatsapp: a.barbeiros?.telefone_whatsapp,
          dono_whatsapp:     a.barbearias?.whatsapp_dono,
          data_hora:         a.data_hora,
        },
      }),
    }).catch(err => console.error('Falha ao notificar cancelamento:', err));

    return res.status(200).json({
      success: true,
      message: 'Agendamento cancelado com sucesso.',
    });

  } catch (e) {
    console.error('Erro ao cancelar agendamento:', e);
    return res.status(500).json({ success: false, message: 'Erro interno ao processar cancelamento.' });
  }
}

async function supaFetch(supabaseUrl, serviceKey, path, opts = {}) {
  const res = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    method: opts.method || 'GET',
    headers: {
      'apikey': serviceKey,
      'Authorization': `Bearer ${serviceKey}`,
      'Content-Type': 'application/json',
      'Prefer': 'return=representation',
    },
    body: opts.body,
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Supabase ${res.status}: ${err}`);
  }

  const text = await res.text();
  return text ? JSON.parse(text) : null;
}
