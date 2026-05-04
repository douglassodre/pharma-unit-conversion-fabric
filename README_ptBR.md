# 💊 Fator de Conversão de Unidades Farmacêuticas — Engenharia de Dados com Power Query M (Microsoft Fabric)

## 🎯 Visão Geral e Impacto ao Negócio

Este projeto resolve um problema crítico de qualidade de dados comum em **sistemas ERP do setor de saúde**: o cadastro de produtos possui informações de unidade de medida (volume, peso, UI) inseridas como texto livre dentro do campo de descrição. Essa falta de estruturação impossibilita a comparação de preços por volume, a análise correta de inventário e o cálculo de dosagens diretamente pelo banco de dados.

A solução implementada consiste em um **pipeline automatizado de ingestão e transformação de dados** construído com a **Linguagem M (Power Query)** no **Microsoft Fabric (Dataflow Gen2)**. O pipeline enriquece a base de produtos derivando uma nova coluna estruturada de `fator_de_conversao`, sem a necessidade de alterar a estrutura ou rotinas do sistema de origem.

### 🚀 Ganhos Obtidos
- **Padronização de Custos:** Viabilização do cálculo de preço padronizado (ex: Custo por ML, Custo por Grama), permitindo comparações financeiras precisas entre fornecedores e marcas distintas.
- **Gestão de Estoque:** Possibilidade de agregar o inventário por volume real disponível, em vez de contar apenas quantidades genéricas de frascos ou caixas de tamanhos variados.
- **Automação de BI:** Alimentação correta de dashboards e Data Warehouses com dados higienizados e prontos para consumo analítico.
- **Escalabilidade:** Lógica resiliente que processa novos cadastros de produtos de forma automatizada, reduzindo o trabalho manual da equipe de suprimentos e cadastro corporativo.

---

## 🔄 Antes e Depois: O Poder da Transformação

Abaixo, demonstra-se o estado dos dados antes de passarem pela camada de transformação e como eles são entregues para a camada analítica.

### ❌ Antes (Origem Não Estruturada)
O sistema armazenava a unidade de medida (ml, UI, gr) embutida na descrição, sem padrão de formatação (maiúsculas, minúsculas, pontuações variáveis e marcações de tamanho distintas).

| Código do Produto | Descrição do Produto | Preço de Entrada |
|---|---|---|
| 10012 | AMOXICILINA 250 mg/5 ml susp.oral fr.75ML | R$ 15,00 |
| 10013 | FLUOXETINA 20 mg/ml sol. oral fr. 20 ml | R$ 8,00 |
| 10014 | HEPARINA SODICA 5000 UI/0,25 ML SUBCUT | R$ 45,00 |

### ✅ Depois (Dados Enriquecidos)
Após o pipeline de engenharia de dados, informações vitais são extraídas utilizando estratégias robustas de *parsing*, gerando a coluna de fator de conversão essencial para as métricas.

| Código | Descrição do Produto | Fator_Conversao | Unidade | Preço Normalizado (por Unidade) |
|---|---|---|---|---|
| 10012 | AMOXICILINA 250 mg/5 ml susp.oral fr.75ML | **75** | ML | R$ 0,20 / ML |
| 10013 | FLUOXETINA 20 mg/ml sol. oral fr. 20 ml | **20** | ML | R$ 0,40 / ML |
| 10014 | HEPARINA SODICA 5000 UI/0,25 ML SUBCUT | **5000** | UI | R$ 0,009 / UI |

---

## 🛠️ Técnicas de Extração e Arquitetura

Como a origem de texto livre não possui um padrão único (e as expressões regulares não são processadas nativamente de forma direta na Linguagem M), desenvolveu-se uma **estratégia de extração em múltiplas camadas** com regras explícitas de prioridade e *fallback*:

1. **Detecção Baseada em Posição e Delimitadores:** Utilização combinada de funções nativas como `Splitter.SplitTextByDelimiter`, `List.Reverse` e `Text.Middle` para isolar a porção numérica imediatamente anterior ao marcador de unidade (ex: identificando e separando os textos " ML" ou " ml").
2. **Tratamento de Exceções Escalonado (Error Handling):** Cada passo de extração engloba tratamentos de erros estruturados (`Table.ReplaceErrorValues`), atribuindo valores de sentinela para falhas matemáticas. Isso permite acionar métodos alternativos automaticamente quando o padrão primário falha.
3. **Tabela de Referência para Casos Críticos:** Para nomenclaturas complexas que exigem conhecimento especializado de negócio (ex: concentrações de insulina, hormônios medidos em Unidades Internacionais, ou nutrição enteral), o pipeline aciona uma rotina de *override*, validando a descrição contra uma tabela de referências rigorosamente mapeadas.
4. **Unificação Condicional Final:** O valor final da coluna de conversão é consolidado por um sistema de prioridade em cascata (Força de Override -> Padrão Letras Maiúsculas -> Padrão Letras Minúsculas -> Valor Default/Unitário).

### Arquitetura Simplificada
`Banco de Dados Origem (ERP) ➡️ Microsoft Fabric (Dataflow Gen2) ➡️ Pipeline Power Query (Regras de Extração) ➡️ Base Analítica Enriquecida`
