# 🏦 OFX + TASY — Gerador e Integração (Bradesco / BNB e outros)

Projeto de importação e geração de extratos bancários no formato **OFX** para o **TASY** (conciliação bancária).

Reúne duas frentes que trabalham juntas:

1. **Gerador de OFX** — cria arquivos OFX para contas que **não** têm exportação (ex.: conta de aplicação do Bradesco), a partir de um formulário simples.
2. **Integração no TASY** — procedure + trigger que importam o OFX automaticamente para dentro do TASY.

---

## 📂 Estrutura

```
Gerador-OFX/
├── Gerador_OFX.html                         # o gerador (publicado no GitHub Pages)
├── procedures/
│   ├── IMPORTA_EXTRATO_OFX_BRADESCO.sql      # procedure ATUAL (corrigida)
│   └── TRIGGER_PRODUCAO.sql                  # trigger que dispara a importação
└── docs/
    ├── README_integracao.md                 # documentação detalhada do fluxo
    └── legado/
        └── PROCEDURE_PRODUCAO_antiga.sql     # versão anterior (com bug) — só histórico
```

---

## 🧮 Gerador de OFX

Página web (roda no navegador, offline após o 1º acesso):

**➡️ https://sergiomanoel81-ui.github.io/Gerador-OFX/Gerador_OFX.html**

- Formulário com campos obrigatórios destacados em vermelho
- Lista de bancos (Banco do Brasil, Caixa, Bradesco, Banco do Nordeste) com código embutido
- Importação de planilha Excel (`.xls`/`.xlsx`) e modelo para download
- Remove acentos e monta o OFX no formato que a procedure importa
- Calcula o saldo inicial automaticamente (saldo final − créditos + débitos)

---

## ⚙️ Integração no TASY

### `procedures/IMPORTA_EXTRATO_OFX_BRADESCO.sql` (atual)

Versão **refatorada e corrigida**. Faz o parsing por bloco `<STMTTRN>`, o que a torna
imune ao formato do arquivo. Principais características:

- Lê tags com valor "aberto" (`<TRNAMT>-55.00`) **ou** fechado na mesma linha (`<TRNAMT>-55.00</TRNAMT>`)
- Conversão de valor robusta (formatos `1.234,56`, `1234,56`, `1,234.56`, ponto)
- Lê o saldo apenas de dentro de `<LEDGERBAL>` (ignora `AVAILBAL`)
- Deduplicação por `FITID` (guardado em `DS_OBSERVACAO`) — reimportar não duplica
- Erros de valor/data **abortam com mensagem** em vez de gravar lançamento zerado

### `procedures/TRIGGER_PRODUCAO.sql`

Monitora a `W_INTERF_CONCIL` e, ao detectar a tag `</OFX>` (fim do upload), chama a
procedure de importação automaticamente — sem intervenção manual.

> Fluxo completo documentado em [`docs/README_integracao.md`](docs/README_integracao.md).

---

## 🐞 Histórico da correção

O banco passou a exportar o OFX com as **tags de valor fechadas na mesma linha**
(`<TRNAMT>-55.00</TRNAMT>`) e vírgula decimal no saldo. A procedure antiga usava um
regex guloso que capturava a tag de fechamento junto com o valor, e um `WHEN OTHERS`
que engolia o erro — gravando lançamento **zerado** silenciosamente. A versão atual
resolve isso de raiz. A versão antiga fica em `docs/legado/` apenas para referência.
