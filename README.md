# Blender Play

*(antes Loveploy; mismo programa, mismos datos y ajustes)*

**Hecho por [Blender.mx](https://blender.mx) · Alejandro Reed.**

App de barra de menú para Mac que junta tres cosas:

1. **Tus cuentas de Claude, abiertas a la vez.** Es [MultiClaude](https://github.com/QuentinCar0n/multiclaude) de Soma Labs, incluido completo: un perfil por cuenta, colores, una app por perfil, Claude Code por cuenta, uso de tokens, mantener la Mac despierta y lo demás.
2. **Grupos de sesiones de Claude Code.** Guarda grupos de hasta 8 sesiones (de esta Mac o de claude.ai/code, de cualquier cuenta) y ábrelas de un clic en una ventana dividida.
3. **Publicar Lovable.** Publica de un clic los proyectos de [Lovable](https://lovable.dev) que estén desactualizados, con modo Turbo, GitHub e iOS.

## 🪟 Grupos de sesiones

Un grupo es un escenario de trabajo: hasta **8 sesiones de Claude Code** que se abren juntas en **una ventana dividida**, como en Claude desktop, acomodadas como tú decidas.

- **Sesiones de esta Mac**: Blender Play lista las sesiones de Claude Code de cada cuenta (las de la terminal y las del Code tab de la app, y las de cualquier carpeta `~/.claude*`) con su título, carpeta y cuenta. Puedes buscarlas, filtrarlas por cuenta, verlas agrupadas por carpeta y marcar varias para agregarlas de una vez. Cada panel es una terminal que reanuda la sesión con `claude --resume` en su carpeta, con la cuenta correcta (`CLAUDE_CONFIG_DIR` del perfil). También puedes empezar una sesión nueva en la carpeta que elijas.
- **Desde tu Chrome**: la pestaña **En Chrome** lista lo que tienes abierto de claude.ai en Chrome (pestañas y apps instaladas de Chrome) y, si tienes abierto claude.ai/code, todas las sesiones que lista su barra lateral. Un clic las agrega como **Ventana de Chrome** (tu propio Chrome, con tu sesión: Blender Play acomoda esa ventana encima de su panel y la sigue cuando mueves el grupo) o **Dentro de Blender Play**. La pestaña **En la nube** lee las sesiones de claude.ai/code de cada cuenta. macOS pide una vez permiso para controlar Chrome.
- **Sesiones de la nube**: pega la dirección de una sesión de claude.ai/code (o crea una nueva) y elige la cuenta. Cada cuenta guarda su propio inicio de sesión de claude.ai, así que en un mismo grupo puedes mezclar cuentas.
- **Acomodo**: cuadrícula, columnas, filas o uno grande y el resto a un lado. Los divisores se arrastran, **Igualar** (⌥⌘=) deja todos los paneles del mismo ancho y alto (también al cambiar el acomodo o agregar o quitar una sesión), y cada panel se puede mover antes o después, reiniciar, abrir en Terminal o en el navegador, o quitar.
- **Varias ventanas**: cada grupo tiene su propia ventana y recuerda en qué pantalla estaba, en qué posición y de qué tamaño. Puedes tener varias abiertas a la vez, una por escenario.
- **Tecla rápida por grupo**: en la ventana del grupo, **Tecla rápida** graba una combinación (por ejemplo ⌃⌥⌘1) que trae esa ventana al frente desde cualquier app, en la pantalla o el escritorio donde esté, para revisar tus chats al instante. En el panel, clic derecho en un grupo asigna la siguiente libre.
- **De un botón**: en el panel de la barra, clic en un grupo lo abre tal como lo dejaste, y **Abrir todos** abre todos tus escenarios a la vez. Los marcados con **Abrir al iniciar** se abren solos al arrancar Blender Play.

**Dictado**: el micrófono en la barra de cada panel graba tu voz, la transcribe en la Mac (en español, en el equipo cuando se puede) y escribe el texto donde estabas escribiendo, en claude.ai o en la terminal de Claude Code. El micrófono de claude.ai (modo de voz) también funciona dentro de los paneles web. macOS pide permiso de micrófono y de reconocimiento de voz la primera vez.

Los paneles web descargan archivos a tu carpeta Descargas y te dejan adjuntar archivos. ⌘C, ⌘V, ⌘X, ⌘A y ⌘Z funcionan en las terminales y en los campos de texto.

Mientras hay una ventana de grupo abierta, Blender Play aparece en el Dock y en ⌘-Tab como cualquier app. Al cerrar un grupo con sesiones locales, Blender Play avisa: las sesiones quedan guardadas y se reanudan al volver a abrirlo.

## 📊 Consumo

- **Cuánto queda de la semana**: con **Mostrar cuánto queda de la semana** (lee los límites de claude.ai de cada cuenta), el panel muestra una barra por cuenta con el porcentaje que te queda del límite semanal, cuándo se renueva y el límite de 5 horas. La barra de menú muestra una pila pequeña con lo que queda de la cuenta más cerca del límite (en rojo con 15 % o menos). Se puede quitar con **Semana en la barra de menú**.
- **Horas de desarrollo**: hoy, esta semana y los últimos 30 días. Cuenta cada bloque de 5 minutos en que tú o Claude Code escribieron en una sesión de esta Mac (terminal, Code tab y Cowork), leyendo las transcripciones de Claude Code. Se guardan en `~/Library/Application Support/Loveploy/dev-hours.json`.

## 🧭 Panel corto y ventana de Blender Play

El panel de la barra de menú muestra solo lo de todos los días: tus grupos (un clic los abre), Lovable en una línea con **Publicar**, lo que queda de la semana, las horas de hoy y tus perfiles. Si no cabe en la pantalla, se desplaza. Todo lo demás está en la **ventana de Blender Play** (clic en «Blender Play» arriba del panel o en **Abrir Blender Play…**): panel completo con ajustes, grupos (nombre, tecla rápida, proyecto, abrir al iniciar), Lovable, proyectos y cobro, y consumo detallado. **Panel corto** se puede apagar para ver todo en el panel como antes.

## 🪶 Memoria

- Las horas y tokens se leen de las transcripciones sin cargar cada línea completa (pueden pesar megas), así que la memoria no crece con el historial.
- Cada panel web dentro de Blender Play es un proceso de WebKit; al minimizar la ventana del grupo se liberan y vuelven al mostrarla.
- **Ahorro de memoria** (en Grupos de sesiones de la ventana de Blender Play): los paneles web se pausan cuando llevas 10 minutos fuera de su ventana sin usarlos y vuelven al regresar a ella; las terminales de Claude Code se pausan tras 30 minutos sin escribir ni recibir nada y se reanudan con un clic donde iban (`claude --resume`). El panel en el que escribes nunca se pausa. Los tiempos se ajustan o se apagan, y **Liberar memoria** en la ventana del grupo pausa ya todo lo que no estás usando. Las **ventanas de Chrome** no gastan memoria extra en Blender Play.
- Cada sesión local es un proceso de Claude Code: ocho sesiones abiertas son ocho procesos.

## ⌨️ Atajos globales

Funcionan desde cualquier app (y desde el macro pad):

| Atajo | Qué hace |
| - | - |
| La tecla rápida de cada grupo (p. ej. ⌥1) | Trae al frente la ventana del grupo, en la pantalla o escritorio donde esté |
| ⌃⌥⌘P | Publica los proyectos de Lovable pendientes |
| ⌃⌥⌘D | Dictar: la primera vez empieza a escuchar; la segunda escribe el texto y lo envía. Va al panel en el que estás escribiendo o, si estás en otra app, a esa app (necesita permiso de Accesibilidad) |
| ⌃⌥⌘U | Abre el consumo de hoy |
| ⌃⌥⌘M | Abre el panel de la barra de menú |

## 💼 Proyectos y cobro

Cada ventana de grupo, o cada sesión por separado, se puede asignar a un **proyecto** (botón del maletín). Blender Play suma por proyecto, de todas las ventanas que trabajaron en él:

- **Horas**: tiempo real de desarrollo (cada bloque de 5 minutos con actividad cuenta una vez aunque varias ventanas trabajaran a la vez) y, aparte, las horas de todas las sesiones sumadas.
- **Tokens y su valor en dinero**: por modelo, valuados a los precios de la API de Anthropic en dólares (lo que costaría ese trabajo por API; con una suscripción no se cobra por token).
- **Honorarios**: si le pones tarifa por hora al proyecto, horas × tarifa en la moneda que elijas.

Las sesiones de la nube también cuentan tiempo: un panel web suma cada bloque de 5 minutos en que escribiste, diste clic o Claude escribió algo nuevo, y una ventana de Chrome del grupo suma mientras la tienes al frente (sus tokens no se pueden leer desde la Mac). También cuentan las sesiones que corren dentro de las carpetas que le agregues al proyecto. Las sesiones nuevas que abres desde un grupo reciben su identificador desde el principio, así que se miden desde el primer minuto. En **Proyectos y cobro…** (sección Consumo del panel) eliges el periodo (este mes, mes pasado, 7 días, todo) y exportas un CSV para facturar.

## 🚀 Lovable

En el panel, la sección **Lovable** muestra cuántos proyectos faltan por publicar, el interruptor de Turbo y el botón para publicarlos. **Abrir proyectos…** abre la lista completa en su propia ventana. El ícono de la barra suma `♥N` cuando hay proyectos por publicar.

- **Sin API keys ni MCP.** Inicias sesión en lovable.dev dentro de la app (Google, GitHub o correo, como siempre) y Blender Play usa esa misma sesión, igual que el navegador.
- La lista muestra todos tus proyectos, de todos tus workspaces, con su estado: **Desactualizado**, **Al día** o **Sin publicar**.
- Con las casillas eliges cuáles entran a la lista de despliegue. Si quitas uno desactualizado, Blender Play lo recuerda y no lo vuelve a incluir.
- **Publicar N proyectos** los publica (3 a la vez) igual que el botón Publish / Update de Lovable, muestra el paso en que va cada uno y te avisa con una notificación al terminar.

### ⚡ Turbo: publicar automáticamente

Activa **Turbo** con el botón ⚡ del menú (o en Ajustes) y Blender Play publica solo cada proyecto en cuanto se desactualiza:

- Revisa cada 2 minutos mientras Turbo está activo; el ícono de la barra cambia a un corazón con rayo.
- **Espera a que los cambios se asienten**: solo publica cuando el proyecto lleva un tiempo sin cambios (5 minutos por defecto; también 0, 2, 10 o 30), para no publicar a medias mientras tú o el agente de Lovable siguen editando. Cada proyecto muestra a qué hora sale.
- **Respeta las exclusiones**: lo que desmarcaste no se publica solo.
- **No se cicla**: si una publicación falla, no la reintenta hasta que haya un cambio nuevo, y te avisa con una notificación.
- No publica proyectos que nunca has publicado; esos siguen siendo manuales.

La Mac tiene que estar encendida con Blender Play abierto; para que arranque solo, activa **Abrir al iniciar sesión en la Mac** en Ajustes.

### 📱 Apps de iOS: TestFlight y App Store

Para los proyectos que tienen app de iOS en Lovable, cada fila muestra dos líneas más, y la pestaña **iOS** junta solo esos proyectos:

- **TestFlight**: si el último build subido se hizo con el último código del proyecto (**al día**) o con uno anterior (**desactualizado: falta subir el último código**). También avisa si hay una subida en curso o si la última falló. Es la misma regla con la que Lovable decide si ofrecer una nueva subida.
- **App Store**: qué versión está **en vivo** y si hay un build más nuevo que todavía no sale, con su estado en Apple: procesando, procesada sin enviar a revisión, en revisión o rechazada.

Arriba de la lista aparece cuántas apps de iOS tienen código sin subir a TestFlight. Con clic derecho → **Abrir App Store Connect**.

Los envíos a revisión de la App Store se siguen haciendo desde Lovable o App Store Connect.

### Blender Dev Apps: TestFlight y App Store de las apps nativas

Las apps nativas del ecosistema (Capacitor, compiladas por Xcode Cloud) viven en el catálogo de **Blender Dev Apps**. Conecta el hub en Ajustes con la URL de su MCP y una llave de alcance `devops` (se guardan en el Llavero; no van en el código) y cada proyecto de Lovable se empareja con su app del catálogo por el repo que Lovable sincroniza. Si un repo tiene varias apps, se muestran todas.

Por cada app se ve lo mismo que el tablero de `/dev` (`panel_salud`):

- **TestFlight al día** o **desactualizado desde …: «mensaje del commit»**, cuando hay cambios nativos que ningún build exitoso incluye (`ios_pendiente_commit`). Los cambios solo web no cuentan. También si Xcode Cloud está compilando o si el último build falló.
- **App Store**: versión, build y estado (en la App Store, esperando revisión, en preparación, rechazada).

**Pedir TestFlight** (clic derecho → *Pedir TestFlight de …*, o en la pestaña iOS *Pedir N TestFlight*) usa `build_disparar`, el mismo camino que el botón del portal. En Ajustes eliges cómo:

- **Preguntar siempre (tope 7/día)**: antes de pedir muestra cuántos builds van hoy del tope de 7 (y avisa si se pasa) y, con un token de GitHub, si los checks del commit pendiente están en verde.
- **Automático con Turbo, sin tope**: con Turbo activo, Blender Play pide TestFlight solo en cuanto una app tiene cambios nativos sin compilar que ya llevan el tiempo de Turbo sin moverse. Pide una vez por cambio; si ese build falla, espera al siguiente cambio.

También desde el clic derecho de cada app:

- **Enviar a revisión de App Store…**: adjunta el build válido más reciente a la versión en preparación (`version_adjuntar_build`) y la envía (`enviar_a_revision`). Es público e irreversible, así que **siempre pregunta**, aunque TestFlight sea automático. Solo aparece cuando la versión está en preparación o rechazada.
- **Compilar Android**: pide el build de Android (`build_disparar`, canal beta).

## Cómo sabe qué está desactualizado

Usa la misma regla que el botón **Publish** de lovable.dev para ofrecer **Update**. Un proyecto está desactualizado cuando:

- su último commit no es el que está publicado, o
- cambiaron los secretos desde la última publicación.

No hace falta llevar registro propio: Lovable dice qué commit está en vivo.

### GitHub

Para cada proyecto conectado a GitHub, Blender Play le pregunta a Lovable a qué repo y rama está sincronizado y cómo va esa sincronización:

- **En sync**: Lovable y GitHub están en el mismo commit.
- **GitHub va adelante**: hay pushes (de tu IDE, de un PR o de otra persona) que Lovable aún no jala. Publicar no los incluiría, así que aparece un aviso en naranja.
- **Se separaron**: hay que resolver la sincronización en Lovable.

Si además conectas un token de GitHub (opcional, en Ajustes), cada proyecto desactualizado muestra cuántos commits faltan por publicar y el mensaje del más reciente (pasa el cursor para ver la lista). El token solo necesita lectura: un [fine-grained token](https://github.com/settings/personal-access-tokens/new) con **Contents: Read** y **Metadata: Read**, o un token clásico con `repo`.

## Cómo funciona por dentro

Blender Play no usa la API pública ni el MCP de Lovable. Hace lo mismo que la página de lovable.dev:

1. **Login**: abre lovable.dev en una ventana con WebKit. Cuando inicias sesión, lee la sesión de Firebase que la página guarda en el navegador (IndexedDB) y la guarda en el Llavero de tu Mac.
2. **Renovar sesión**: renueva el token como lo hace el SDK de Firebase de la página. Si eso falla, abre lovable.dev en segundo plano para que la propia página lo renueve. Si tampoco funciona, te pide iniciar sesión otra vez.
3. **Datos**: llama a los mismos endpoints que usa la web de Lovable, con tu sesión:

| Para qué | Endpoint |
| - | - |
| Tus workspaces | `GET /user/workspaces` |
| Proyectos del workspace | `GET /v2/workspaces/{ws}/projects` |
| Commit publicado vs. último commit | WebSocket `wss://api.lovable.dev/realtime`, suscripción `project` (lo mismo que lee el editor); `GET /projects/{id}/details` si no responde |
| Repo y rama de GitHub | `GET /workspaces/{ws}/projects/{id}/gitsync` |
| Lovable vs. GitHub | `GET /workspaces/{ws}/projects/{id}/gitsync/sync-status` |
| Publicar (botón Publish / Update) | `POST /projects/{id}/deployments` |
| Avance de la publicación | `GET /projects/{id}/deployments/{deployment_id}/progress` |
| Builds de iOS (commit de cada subida) | `GET /projects/{id}/build-runs?flow=manual&target=ios` |
| Versiones en TestFlight / App Store | `GET /projects/{id}/mobile-publish/store-builds` |

Con Blender Dev Apps habla por su MCP, con la URL y la llave que pones en Ajustes: `panel_salud`, `builds_recientes`, `build_disparar`, `version_adjuntar_build` y `enviar_a_revision`.

Estos endpoints son internos de la web de Lovable, no una API documentada. Si Lovable los cambia, Blender Play puede dejar de funcionar hasta que se actualice.

`Cerrar sesión` borra la sesión del Llavero y los datos de lovable.dev del navegador interno. Lo único que se guarda en disco son los proyectos excluidos, en `~/Library/Application Support/Loveploy/state.json`.

## Requisitos

- macOS 15 (Sequoia) o más nuevo.
- La [app de Claude](https://claude.ai/download) en `/Applications` para las cuentas, y [Claude Code](https://docs.claude.com/en/docs/claude-code) instalado para las sesiones locales.
- Una cuenta de Lovable con permiso para publicar los proyectos. No importa el plan.

Si ya usabas MultiClaude, la primera vez Blender Play toma sus perfiles y ajustes. Cierra MultiClaude y quítalo: los dos manejan las mismas ventanas de Claude y los mismos enlaces de inicio de sesión, así que no deben correr a la vez. Blender Play no se actualiza solo desde los releases de MultiClaude.

## Instalar

### Desde GitHub Actions

Cada push a `main` compila la app. En la pestaña **Actions** abre la última ejecución de **Build** y descarga el artefacto **Blender Play**. Descomprime, mueve `Blender Play.app` a Aplicaciones y la primera vez ábrela con clic derecho → **Abrir** (no está notarizada).

### Compilando en tu Mac

Necesitas Xcode 16 o más nuevo (`xcode-select --install` para las Command Line Tools).

```bash
git clone https://github.com/alereed/loveploy.git
cd loveploy
scripts/build-app.sh --install
```

Eso compila `dist/Blender Play.app` (universal, Apple Silicon e Intel), la copia a `/Applications` y la abre.

## Uso

1. Clic en el ✳ de la barra de menú. Ahí están tus cuentas de Claude, los grupos de sesiones y la sección Lovable.
2. **Grupos de sesiones → Nuevo grupo…**, ponle nombre y en su ventana usa **Agregar sesión** para llenarlo (hasta 8). Elige el acomodo arriba.
3. **Lovable → Iniciar sesión en Lovable…** la primera vez; luego **Abrir proyectos…** para ver la lista, marcar y publicar.
4. En **Settings** están las opciones de cuentas de Claude, incluida **Launch at Login**.

## Estructura

```
Sources/LoveployCore/            Sesión y clientes de lovable.dev, GitHub y Blender Dev Apps; regla de desactualizado;
                                 despliegue; grupos de sesiones (también compila en Linux)
Sources/Loveploy/main.swift      MultiClaude 1.6.1 (Apache 2.0), con los cambios marcados "Loveploy:"
Sources/Loveploy/                Lovable, grupos de sesiones (terminales con SwiftTerm y paneles web) y login con WebKit
Tests/                           Pruebas del núcleo: swift test
scripts/build-app.sh             Arma Blender Play.app
```

## Licencias

Blender Play es de Alejandro Reed, [Blender.mx](https://blender.mx), y se publica bajo la licencia MIT (`LICENSE`). Incluye MultiClaude de Soma Labs bajo la Apache License 2.0 (`LICENSE-MultiClaude` y `NOTICE`) y usa [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) para las terminales.
