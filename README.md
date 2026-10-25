# Loveploy

App de barra de menú para Mac que publica de un clic todos tus proyectos de [Lovable](https://lovable.dev) que estén desactualizados.

- **Sin API keys ni MCP.** Inicias sesión en lovable.dev dentro de la app (Google, GitHub o correo, como siempre) y Loveploy usa esa misma sesión, igual que el navegador.
- El ícono de la barra muestra cuántos proyectos tienen cambios sin publicar.
- Al darle clic se abre la lista de todos tus proyectos, de todos tus workspaces, con su estado: **Desactualizado**, **Al día** o **Sin publicar**.
- Con las casillas eliges cuáles entran a la lista de despliegue. Si quitas uno desactualizado, Loveploy lo recuerda y no lo vuelve a incluir.
- **Publicar N proyectos** los publica (3 a la vez) igual que el botón Publish / Update de Lovable, muestra el paso en que va cada uno y te avisa con una notificación al terminar.

## ⚡ Turbo: publicar automáticamente

Activa **Turbo** con el botón ⚡ del menú (o en Ajustes) y Loveploy publica solo cada proyecto en cuanto se desactualiza:

- Revisa cada 2 minutos mientras Turbo está activo; el ícono de la barra cambia a un corazón con rayo.
- **Espera a que los cambios se asienten**: solo publica cuando el proyecto lleva un tiempo sin cambios (5 minutos por defecto; también 0, 2, 10 o 30), para no publicar a medias mientras tú o el agente de Lovable siguen editando. Cada proyecto muestra a qué hora sale.
- **Respeta las exclusiones**: lo que desmarcaste no se publica solo.
- **No se cicla**: si una publicación falla, no la reintenta hasta que haya un cambio nuevo, y te avisa con una notificación.
- No publica proyectos que nunca has publicado; esos siguen siendo manuales.

La Mac tiene que estar encendida con Loveploy abierto; para que arranque solo, activa **Abrir al iniciar sesión en la Mac** en Ajustes.

## 📱 Apps de iOS: TestFlight y App Store

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

**Pedir TestFlight** (clic derecho → *Pedir TestFlight de … (Xcode Cloud)…*, o en la pestaña iOS *Pedir N TestFlight…*) usa `build_disparar`, el mismo camino que el botón del portal. Como cuesta horas de Xcode Cloud, Loveploy **siempre pregunta antes** y muestra:

- cuántos builds de Xcode Cloud van hoy del tope de 7, y avisa si con estos se pasa;
- con un token de GitHub, si los checks del commit pendiente (por ejemplo el del Mac mini) están en verde, rojos o sin correr.

Turbo nunca pide TestFlight por su cuenta. Los envíos a revisión de la App Store se siguen haciendo desde el portal.

## Cómo sabe qué está desactualizado

Usa la misma regla que el botón **Publish** de lovable.dev para ofrecer **Update**. Un proyecto está desactualizado cuando:

- su último commit no es el que está publicado, o
- cambiaron los secretos desde la última publicación.

No hace falta llevar registro propio: Lovable dice qué commit está en vivo.

### GitHub

Para cada proyecto conectado a GitHub, Loveploy le pregunta a Lovable a qué repo y rama está sincronizado y cómo va esa sincronización:

- **En sync**: Lovable y GitHub están en el mismo commit.
- **GitHub va adelante**: hay pushes (de tu IDE, de un PR o de otra persona) que Lovable aún no jala. Publicar no los incluiría, así que aparece un aviso en naranja.
- **Se separaron**: hay que resolver la sincronización en Lovable.

Si además conectas un token de GitHub (opcional, en Ajustes), cada proyecto desactualizado muestra cuántos commits faltan por publicar y el mensaje del más reciente (pasa el cursor para ver la lista). El token solo necesita lectura: un [fine-grained token](https://github.com/settings/personal-access-tokens/new) con **Contents: Read** y **Metadata: Read**, o un token clásico con `repo`.

## Cómo funciona por dentro

Loveploy no usa la API pública ni el MCP de Lovable. Hace lo mismo que la página de lovable.dev:

1. **Login**: abre lovable.dev en una ventana con WebKit. Cuando inicias sesión, lee la sesión de Firebase que la página guarda en el navegador (IndexedDB) y la guarda en el Llavero de tu Mac.
2. **Renovar sesión**: renueva el token como lo hace el SDK de Firebase de la página. Si eso falla, abre lovable.dev en segundo plano para que la propia página lo renueve. Si tampoco funciona, te pide iniciar sesión otra vez.
3. **Datos**: llama a los mismos endpoints que usa la web de Lovable, con tu sesión:

| Para qué | Endpoint |
| - | - |
| Tus workspaces | `GET /user/workspaces` |
| Proyectos del workspace | `GET /v2/workspaces/{ws}/projects` |
| Commit publicado vs. último commit | `GET /projects/{id}/details` |
| Repo y rama de GitHub | `GET /workspaces/{ws}/projects/{id}/gitsync` |
| Lovable vs. GitHub | `GET /workspaces/{ws}/projects/{id}/gitsync/sync-status` |
| Publicar (botón Publish / Update) | `POST /projects/{id}/deployments` |
| Avance de la publicación | `GET /projects/{id}/deployments/{deployment_id}/progress` |
| Builds de iOS (commit de cada subida) | `GET /projects/{id}/build-runs?flow=manual&target=ios` |
| Versiones en TestFlight / App Store | `GET /projects/{id}/mobile-publish/store-builds` |

Con Blender Dev Apps habla por su MCP, con la URL y la llave que pones en Ajustes: `panel_salud`, `builds_recientes` y `build_disparar`.

Estos endpoints son internos de la web de Lovable, no una API documentada. Si Lovable los cambia, Loveploy puede dejar de funcionar hasta que se actualice.

`Cerrar sesión` borra la sesión del Llavero y los datos de lovable.dev del navegador interno. Lo único que se guarda en disco son los proyectos excluidos, en `~/Library/Application Support/Loveploy/state.json`.

## Requisitos

- macOS 13 (Ventura) o más nuevo.
- Una cuenta de Lovable con permiso para publicar los proyectos. No importa el plan.

## Instalar

### Desde GitHub Actions

Cada push a `main` compila la app. En la pestaña **Actions** abre la última ejecución de **Build** y descarga el artefacto **Loveploy**. Descomprime, mueve `Loveploy.app` a Aplicaciones y la primera vez ábrela con clic derecho → **Abrir** (no está notarizada).

### Compilando en tu Mac

Necesitas Xcode o las Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/alereed/loveploy.git
cd loveploy
scripts/build-app.sh --install
```

Eso compila `dist/Loveploy.app` (universal, Apple Silicon e Intel), la copia a `/Applications` y la abre.

## Uso

1. Clic en el ícono ♥ de la barra de menú → **Iniciar sesión en Lovable** y entra como siempre.
2. En **Pendientes** ves lo que falta publicar; en **Todos**, todos tus proyectos.
3. Marca o desmarca lo que quieras y dale **Publicar** (o Enter).
4. Clic derecho en un proyecto para abrirlo en Lovable, abrir el sitio publicado o abrir el repo.

La lista se actualiza sola cada 15 minutos y cada vez que abres el menú. En Ajustes puedes activar **Abrir al iniciar sesión en la Mac**.

## Estructura

```
Sources/LoveployCore/   Sesión, clientes de lovable.dev, GitHub y Blender Dev Apps, regla de desactualizado, despliegue (también compila en Linux)
Sources/Loveploy/       App SwiftUI de barra de menú y ventana de login con WebKit
Tests/                  Pruebas del núcleo: swift test
scripts/build-app.sh    Arma Loveploy.app
```
