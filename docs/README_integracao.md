# 🏦 Importação Automática de Extratos OFX - Bradesco para TASY

Sistema de importação automática de extratos bancários do Bradesco (formato OFX) para o TASY.

---

## 📋 O que faz?

Este sistema automatiza completamente a importação de extratos OFX do Bradesco no TASY:

1. Usuário faz upload do arquivo OFX pela interface do TASY
2. Sistema detecta automaticamente o fim do upload
3. Processa todas as transações do arquivo
4. Insere os lançamentos no extrato
5. Calcula e atualiza os saldos
6. Tudo pronto - sem intervenção manual!

---

## 🎯 Arquivos

### 1️⃣ **PROCEDURE_PRODUCAO.sql**

**O que faz:**
- Lê o arquivo OFX linha por linha
- Extrai dados de cada transação (data, valor, histórico, documento)
- Converte valores do formato brasileiro (vírgula) para Oracle (ponto)
- Identifica se é débito ou crédito
- Insere lançamentos na tabela BANCO_EXTRATO_LANC
- Calcula saldo inicial e final
- Atualiza cabeçalho do extrato
- Limpa dados temporários

**Principais características:**
- ✅ Converte valores com vírgula (1.234,56) automaticamente
- ✅ Processa débitos e créditos corretamente
- ✅ Remove acentos dos históricos
- ✅ Calcula saldos automaticamente
- ✅ Retorna saldos para o TASY via parâmetros OUT

---

### 2️⃣ **TRIGGER_PRODUCAO.sql**

**O que faz:**
- Monitora quando arquivos são carregados na tabela W_INTERF_CONCIL
- Detecta quando o arquivo OFX termina de ser carregado (tag `</OFX>`)
- Busca o último extrato criado hoje que ainda não foi processado
- Chama automaticamente a procedure de importação
- Tudo acontece em background, sem intervenção do usuário

**Principais características:**
- ✅ Execução automática (usuário não precisa fazer nada além do upload)
- ✅ Seguro (não propaga erros que possam travar o sistema)
- ✅ Configurável para múltiplas contas

---

## 🚀 Como funciona o fluxo completo?

```
1. Usuário cria extrato no TASY
   ↓
2. Importar extrato → Escolhe arquivo OFX
   ↓
3. TASY carrega arquivo na W_INTERF_CONCIL (linha por linha)
   ↓
4. TRIGGER detecta tag </OFX> (fim do arquivo)
   ↓
5. TRIGGER chama PROCEDURE automaticamente
   ↓
6. PROCEDURE processa todas as transações
   ↓
7. Lançamentos aparecem no extrato
   ✅ PRONTO!
```

---

## 📦 Instalação

```sql
-- 1. Compilar procedure
@PROCEDURE_PRODUCAO.sql

-- 2. Compilar trigger
@TRIGGER_PRODUCAO.sql

-- 3. Configurar interface 50000 no TASY (vinculando às contas do Bradesco)
```

---

## ⚙️ Configuração

### Para adicionar mais contas do Bradesco:

Editar o trigger, linha 24:
```sql
-- De:
IF :NEW.nr_seq_conta IN (32) THEN

-- Para (exemplo com 3 contas):
IF :NEW.nr_seq_conta IN (32, 10, 13) THEN
```

Depois recompilar o trigger.

---

## ✅ Testado e Funcionando

- ✅ 15 transações importadas em < 2 segundos
- ✅ Valores com vírgula convertidos corretamente
- ✅ Débitos e créditos identificados automaticamente
- ✅ Saldos calculados precisamente
- ✅ Em produção no CSB desde 17/12/2025

---

## 📊 Formato OFX Suportado

O sistema processa arquivos OFX padrão do Bradesco:
- Valores com vírgula como decimal (ex: 1.234,56)
- Datas no formato YYYYMMDDHHMMSS
- Tags TRNTYPE (CREDIT/DEBIT)
- Histórico na tag MEMO
- Documento na tag CHECKNUM
- Saldo final na tag BALAMT

---

## 🛠️ Requisitos

- TASY EMR (Philips Healthcare)
- Oracle Database 11g+
- Tabelas: BANCO_EXTRATO, BANCO_EXTRATO_LANC, W_INTERF_CONCIL
- Function: ELIMINA_ACENTUACAO

---

## 👨‍💻 Autor

**Sérgio Cerqueira**  
CSB - Centro de Saúde de Feira de Santana  
Dezembro/2025

---

## 📝 Licença

MIT License - Livre para usar e modificar
