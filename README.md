# Loveploy

App de barra de menú para Mac que publica de un clic todos tus proyectos de [Lovable](https://lovable.dev) que estén desactualizados.

- El ícono de la barra muestra cuántos proyectos tienen pendiente publicarse.
- Al darle clic se abre la lista de todos tus proyectos con su estado: **Desactualizado**, **Sin registro**, **Al día** y **Sin publicar**.
- Con las casillas eliges cuáles entran a la lista de despliegue. Si quitas un proyecto pendiente, Loveploy lo recuerda y no lo vuelve a incluir.
- **Publicar N proyectos** los publica todos (3 a la vez), muestra el avance de cada uno y te avisa con una notificación al terminar.

## Cómo sabe qué está desactualizado

La API de Lovable dice cuál es el último commit de un proyecto (`latest_commit_sha`), pero no qué commit está publicado. Por eso Loveploy guarda qué commit publicó cada vez y compara:

| Estado | Significado | ¿Entra por defecto? |
| - | - | - |
| Desactualizado | Hay commits nuevos desde la última publicación hecha con Loveploy | Sí |
| Sin registro | Está publicado, pero no con Loveploy, así que no sabemos qué versión está en vivo | Sí |
| Al día | Lo publicado coincide con el último commit | No (puedes forzarlo marcando la casilla) |
| Sin publicar | Nunca se ha publicado | No (puedes incluirlo marcando la casilla) |

La primera vez todos los proyectos publicados aparecen como **Sin registro**. Puedes publicarlos todos una vez (las publicaciones no consumen créditos de IA) o, si sabes que ya están al día, usar **Ajustes → Marcar todos los «Sin registro» como al día**. También puedes hacerlo proyecto por proyecto con clic derecho.

Si editas un proyecto desde Lovable y lo publicas ahí mismo, Loveploy lo seguirá viendo como desactualizado. Usa clic derecho → **Marcar como al día**.

El estado se guarda en `~/Library/Application Support/Loveploy/state.json` y las API keys en el Llavero (Keychain).

## Requisitos

- macOS 13 (Ventura) o más nuevo.
- Un workspace de Lovable con plan **Business** o **Enterprise** (la API pública lo requiere).
- Una API key creada en [Workspace settings → API keys & OAuth](https://lovable.dev/settings/api-keys) con los permisos `projects:write` y `workspaces:read`. Las keys son por workspace; si tienes varios workspaces, agrega una key por cada uno.

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

Eso compila `dist/Loveploy.app` (universal, Apple Silicon e Intel), la copia a `/Applications` y la abre. Para desarrollo también funciona `swift run Loveploy`.

## Uso

1. Clic en el ícono ♥ de la barra de menú.
2. La primera vez se abren los ajustes: pega tu API key y dale **Agregar**.
3. En **Pendientes** ves lo que falta publicar; en **Todos**, todos tus proyectos.
4. Marca o desmarca lo que quieras y dale **Publicar** (o Enter).

La lista se actualiza sola cada 15 minutos y cada vez que abres el menú. En Ajustes puedes activar **Abrir al iniciar sesión**.

## Estructura

```
Sources/LoveployCore/   Cliente de la API de Lovable, estado y lógica de despliegue (también compila en Linux)
Sources/Loveploy/       App SwiftUI de barra de menú (MenuBarExtra)
Tests/                  Pruebas del núcleo: swift test
scripts/build-app.sh    Arma Loveploy.app
```

API usada (versión `2026-09-11`): `GET /v1/workspaces`, `GET /v1/projects`, `GET /v1/projects/{id}`, `POST /v1/projects/{id}/publish` y `GET /v1/projects/{id}/publish/{deployment_id}`. Ver la [referencia de la API de Lovable](https://docs.lovable.dev/api-reference/introduction).
