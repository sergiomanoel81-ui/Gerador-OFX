# ⚠️ Legado — não usar em produção

Arquivos aqui são **versões antigas**, mantidas só como histórico.

- `PROCEDURE_PRODUCAO_antiga.sql` — versão anterior da procedure de importação, com o
  bug de parsing (regex guloso + `WHEN OTHERS` que mascarava erro). Foi **substituída**
  por `procedures/IMPORTA_EXTRATO_OFX_BRADESCO.sql` na raiz do projeto.

Use sempre a versão da pasta `procedures/`.
